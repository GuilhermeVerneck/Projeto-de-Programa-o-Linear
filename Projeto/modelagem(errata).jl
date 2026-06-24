using JuMP
using Gurobi
using CSV
using DataFrames
using Printf
using Dates

# ==============================================================================
# ██████████████████████████████████████████████████████████████████████████████
#                    PAINEL DE CONTROLE
#  Altere aqui antes de rodar. O script vai rodar todos os 21 cenários
#  (ocupacao_50 até ocupacao_150) com essa configuração fixa.
# ██████████████████████████████████████████████████████████████████████████████
# ==============================================================================

fabrica_quebrada = "Nenhuma"   # "Nenhuma" | "Extrema" | "Jacarei" | qualquer planta
limite_caminhoes = 80          # 80 (normal) | 40 (greve parcial) | 10 (colapso logístico)
fator_demanda    = 1.0         # 1.0 (normal) | 1.5 (+50%) | 2.0 (dobra) | 3.0 (caos)

# ==============================================================================
# AMBIENTE GUROBI (Criado apenas uma vez para evitar vazamento de memória)
# ==============================================================================
const GRB_ENV = Gurobi.Env()

# ==============================================================================
# CONFIGURAÇÃO DE CAMINHOS
# ==============================================================================
caminho_base = "C:\\Unifesp\\Programação Linear\\Trabalho Programação Linear\\Dados\\"

CENARIOS = ["50","55","60","65","70","75","80","85","90",
            "95","100","105","110","115","120","125","130",
            "135","140","145","150"]

# ==============================================================================
# FUNÇÕES AUXILIARES
# ==============================================================================

# Converte número brasileiro "1.234,56" para Float64 1234.56
# Aceita também valores que já vieram como Float64 ou Int do CSV
function parse_br_float(val)
    ismissing(val) && return 0.0
    val isa Number && return Float64(val)
    s = strip(string(val))
    s == "" && return 0.0
    
    # Se tem vírgula, é formato BR garantido
    if occursin(",", s)
        s = replace(s, "." => "")  # Tira os milhares
        s = replace(s, "," => ".") # Vírgula vira decimal
    else
        # Se só tem ponto, verifica se é uma exportação de milhar do Excel (ex: 120.000)
        partes = split(s, ".")
        if length(partes) == 2 && length(partes[2]) == 3
            s = replace(s, "." => "") # Remove o ponto falso
        end
    end
    return parse(Float64, s)
end

# Barra de progresso simples no terminal
function progresso(atual, total, label="")
    pct    = round(Int, atual / total * 100)
    blocos = round(Int, pct / 5)
    barra  = "█"^blocos * "░"^(20 - blocos)
    print("\r  [$barra] $pct%  $label")
    atual == total && println()
end

# Formata número com separador de milhar manualmente (Julia nao tem %,f)
function fmt_real(x::Real)
    isnan(x) && return "           ---"
    s = @sprintf("%.2f", abs(x))
    partes = split(s, ".")
    inteiro = partes[1]
    decimal = partes[2]
    
    # Faz a separação de milhares com segurança (da direita para a esquerda)
    chars = collect(inteiro)
    resultado = ""
    for (j, c) in enumerate(reverse(chars))
        j > 1 && j % 3 == 1 && (resultado = "." * resultado)
        resultado = string(c) * resultado
    end
    
    x < 0 && (resultado = "-" * resultado)
    return @sprintf("%14s", resultado * "," * decimal)
end

# ==============================================================================
# FUNÇÃO PRINCIPAL: monta e resolve um cenário
# ==============================================================================

function resolver_cenario(cenario, fabrica_quebrada, limite_caminhoes, fator_demanda, df_log)

    caminho_pasta = caminho_base * "ocupacao_" * cenario * "\\"

    # ── Leitura dos dados ────────────────────────────────────────────────────
    df_need  = CSV.read(caminho_pasta * "input_production_need_artificial.csv",    DataFrame)
    df_rate  = CSV.read(caminho_pasta * "input_production_rate_artificial.csv",    DataFrame)
    df_costs = CSV.read(caminho_pasta * "input_sku_costs_artificial.csv",          DataFrame)
    df_limit = CSV.read(caminho_pasta * "input_line_storage_limit_artificial.csv", DataFrame)

    # ── Mapeamento Cronológico do Tempo (Regra do Documento 11) ──────────────
    # Extrai datas limpas (sem hora) de ambas as tabelas
    datas_demanda = [split(string(d), " ")[1] for d in df_need.deadline if !ismissing(d)]
    datas_taxa    = [split(string(d), " ")[1] for d in df_rate.ref_date if !ismissing(d)]
    
    # Une, remove duplicatas e ordena do dia mais antigo para o mais novo
    datas_unicas = sort(unique(vcat(datas_demanda, datas_taxa)))
    
    # Cria o dicionário: "2026-12-01" -> 1, "2026-12-02" -> 2...
    mapa_tempo = Dict(data => t for (t, data) in enumerate(datas_unicas))
    
    # Função local para converter a data usando o mapa
    function get_t(data_str)
        d_limpa = split(string(data_str), " ")[1]
        return get(mapa_tempo, d_limpa, -1)
    end

    # Conversão de formato brasileiro para todos os campos numéricos relevantes
    df_need.prod_need = parse_br_float.(df_need.prod_need)

    # ── Conjuntos (Baseados na estrutura, não na demanda/taxa) ───────────────
    P   = unique(df_rate.plant)
    T   = 1:15
    L_p = Dict(p => unique(df_limit[df_limit.plant .== p, :production_line]) for p in P)
    I   = unique(df_costs.product_id)

    # ── Parâmetros ───────────────────────────────────────────────────────────
    k     = Dict((r.product_id, r.plant, r.production_line) => parse_br_float(r.production_cost) for r in eachrow(df_costs))
    v     = Dict((r.product_id, r.plant, r.production_line) => parse_br_float(r.inventory_cost) for r in eachrow(df_costs))
    ct    = Dict((r.origem, r.destino) => parse_br_float(r.custo_total_frete) for r in eachrow(df_log))
    e_max = Dict((r.plant, r.production_line) => parse_br_float(r.storage_limit) for r in eachrow(df_limit))

    # Demanda (Processamento rápido com get() fallback)
    eta = Dict{Tuple{Any,Any,Any,Int}, Float64}()
    for r in eachrow(df_need)
        t     = extrair_dia(r.deadline)
        chave = (r.product_id, r.plant, r.production_line, t)
        eta[chave] = get(eta, chave, 0.0) + r.prod_need
    end

    # Taxa de produção
    r_taxa = Dict{Tuple{Any,Any,Int}, Float64}()
    for r in eachrow(df_rate)
        t = extrair_dia(r.ref_date)
        r_taxa[(r.plant, r.production_line, t)] = parse_br_float(r.rate)
    end

    # Conjunto C (Capabilidade): Blindado contra erros de digitação nos CSVs
    formatos_da_linha = Dict(r.production_line => strip(lowercase(string(r.sku_size_shape))) for r in eachrow(df_rate))
    formato_do_sku    = Dict(r.product_id => strip(lowercase(string(r.sku_size_shape))) for r in eachrow(df_need))

    C = Set{Tuple{Any, Any, Any}}()
    for i in I, p in P, l in L_p[p]
        if get(formato_do_sku, i, "none_sku") == get(formatos_da_linha, l, "none_line")
            push!(C, (i, p, l))
        end
    end

    # ── Modelo ───────────────────────────────────────────────────────────────
    # Instancia associada ao GRB_ENV global para evitar recriar ambiente e economizar RAM
    modelo = Model(() -> Gurobi.Optimizer(GRB_ENV))
    set_silent(modelo)

    @variable(modelo, x[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, e[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, a[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, f[i in I, o in P, d in P, t in T; o != d] >= 0)
    @variable(modelo, g[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, s[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, w[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, b[i in I, p in P, l in L_p[p], t in T] >= 0) # <--- NOVA VARIÁVEL

    # ── Função objetivo (Protegida contra KeyErrors com punição para rotas irreais) ───
    @objective(modelo, Min,
        sum(get(k, (i,p,l), 9999.0) * x[i,p,l,t]
            for p in P for l in L_p[p] for i in I for t in T if (i,p,l) ∈ C) +
        sum(get(v, (i,p,l), 9999.0) * e[i,p,l,t]
            for p in P for l in L_p[p] for i in I for t in T) +
        sum(get(ct, (o,d), 999999.0) * (f[i,o,d,t] / 200_000)
            for i in I for o in P for d in P for t in T if o != d) +
        sum(50_000 * b[i,p,l,t]     # <--- MULTA POR DIA DE ATRASO
            for p in P for l in L_p[p] for i in I for t in T) +
        sum(1_000_000 * w[i,p,l,t]  # <--- CANCELAMENTO ABSOLUTO
            for p in P for l in L_p[p] for i in I for t in T)
    )
    # ── Restrições ───────────────────────────────────────────────────────────

    # R1: limite de armazenagem (espaço compartilhado entre SKUs)
    @constraint(modelo, R1[p in P, l in L_p[p], t in T],
        sum(e[i,p,l,t] for i in I) <= get(e_max, (p,l), 0.0)
    )

   # ── Parâmetro Extra: Estoque Inicial (Warm-up) ───────────────────────────
    # Assumimos que o armazém começa com 30% da sua capacidade máxima preenchida,
    # distribuída igualmente entre os SKUs que a linha sabe produzir.
    e0 = Dict{Tuple{Any, Any, Any}, Float64}()
    for p in P, l in L_p[p]
        skus_compativeis = [i for i in I if (i,p,l) ∈ C]
        num_skus = max(1, length(skus_compativeis))
        cap_linha = get(e_max, (p,l), 0.0)
        
        for i in I
            if i in skus_compativeis
                e0[(i,p,l)] = (cap_linha * 0.30) / num_skus
            else
                e0[(i,p,l)] = 0.0
            end
        end
    end

    # ... (mantenha a declaração de variáveis e Função Objetivo que você já tem) ...

    # R2: balanço de estoque (com o choque inicial amortecido por e0)
    @constraint(modelo, R2[i in I, p in P, l in L_p[p], t in T],
        e[i,p,l,t] == (t == 1 ? e0[(i,p,l)] : e[i,p,l,t-1]) +
                      x[i,p,l,t] + g[i,p,l,t] - s[i,p,l,t] - a[i,p,l,t]
    )

    # R3: atendimento à demanda com fator de escalonamento e atraso permitido
    @constraint(modelo, R3[i in I, p in P, l in L_p[p], t in T],
        a[i,p,l,t] + b[i,p,l,t] + w[i,p,l,t] == 
        get(eta, (i,p,l,t), 0.0) * fator_demanda + (t == 1 ? 0.0 : b[i,p,l,t-1])
    )

    # R4: capacidade produtiva (planta quebrada => limite 0h)
    @constraint(modelo, R4[p in P, l in L_p[p], t in T],
        sum(x[i,p,l,t] / get(r_taxa, (p,l,t), 0.001)
            for i in I if (i,p,l) ∈ C && get(r_taxa, (p,l,t), 0.0) > 0) <=
        (p == fabrica_quebrada ? 0.0 : 24.0)
    )

    # R5: capacidade logística de saída por planta
    @constraint(modelo, R5[p in P, t in T],
        sum(f[i,p,d,t] / 200_000 for i in I, d in P if d != p) <= limite_caminhoes
    )

    # R6: doca de ENTRADA — o que chega de frete é redistribuído entre as linhas (via g)
    @constraint(modelo, R6[i in I, p in P, t in T],
        sum(g[i,p,l,t] for l in L_p[p]) == sum(f[i,o,p,t] for o in P if o != p)
    )

    # R7: doca de SAÍDA — o que as linhas enviam ao pátio (via s) é carregado nos caminhões
    @constraint(modelo, R7[i in I, p in P, t in T],
        sum(s[i,p,l,t] for l in L_p[p]) == sum(f[i,p,d,t] for d in P if d != p)
    )

    # R8: capabilidade de formato — produção fora de C é zero
    @constraint(modelo, R8[i in I, p in P, l in L_p[p], t in T; (i,p,l) ∉ C],
        x[i,p,l,t] == 0
    )

    # ── Otimização ───────────────────────────────────────────────────────────
    optimize!(modelo)
    status = termination_status(modelo)

    if status ∉ (MOI.OPTIMAL, MOI.FEASIBLE_POINT)
        # Limpeza forçada antes do return prematuro
        empty!(modelo)
        GC.gc()
        return (
            cenario          = cenario,
            status           = string(status),
            custo_producao   = NaN, custo_estoque    = NaN,
            custo_logistica  = NaN, custo_penalidade = NaN,
            custo_total      = NaN, demanda_total    = NaN,
            atendido         = NaN, nao_atendido     = NaN,
            taxa_atendimento = NaN, caminhoes        = NaN,
        )
    end

# ── Métricas ─────────────────────────────────────────────────────────────
    total_w    = sum(value(w[i,p,l,t]) for p in P for l in L_p[p] for i in I for t in T)
    total_a    = sum(value(a[i,p,l,t]) for p in P for l in L_p[p] for i in I for t in T)
    total_b    = sum(value(b[i,p,l,t]) for p in P for l in L_p[p] for i in I for t in T) # <--- CAPTURA O ATRASO
    
    custo_pen_w = total_w * 1_000_000
    custo_pen_b = total_b * 50_000 # <--- CUSTO DO ATRASO
    
    custo_prod = sum(get(k, (i,p,l), 0.0) * value(x[i,p,l,t])
                     for p in P for l in L_p[p] for i in I for t in T if (i,p,l) ∈ C)
    custo_est  = sum(get(v, (i,p,l), 0.0) * value(e[i,p,l,t])
                     for p in P for l in L_p[p] for i in I for t in T)
    custo_log  = sum(get(ct, (o,d), 0.0) * value(f[i,o,d,t]) / 200_000
                     for i in I for o in P for d in P for t in T if o != d)
    caminhoes  = sum(value(f[i,o,d,t]) / 200_000
                     for i in I for o in P for d in P for t in T if o != d)
    
    taxa       = (total_a + total_b + total_w) > 0 ? total_a / (total_a + total_b + total_w) * 100 : 100.0
    obj_val    = objective_value(modelo)

    # Limpeza de Memória
    empty!(modelo)
    GC.gc()

    return (
        cenario          = cenario,
        status           = "OPTIMAL",
        custo_producao   = round(custo_prod,              digits=2),
        custo_estoque    = round(custo_est,               digits=2),
        custo_logistica  = round(custo_log,               digits=2),
        custo_atraso     = round(custo_pen_b,             digits=2), # <--- NOVO
        custo_multa_w    = round(custo_pen_w,             digits=2), # <--- ATUALIZADO
        custo_total      = round(obj_val,                 digits=2),
        demanda_total    = round(total_a + total_b + total_w, digits=0),
        atendido         = round(total_a,                 digits=0),
        nao_atendido     = round(total_w,                 digits=0),
        latas_atrasadas  = round(total_b,                 digits=0), # <--- NOVO
        taxa_atendimento = round(taxa,                    digits=2),
        caminhoes        = round(caminhoes,               digits=1),
    )
end


# ==============================================================================
# OUTPUT NO TERMINAL
# ==============================================================================

function sep(c="─", n=100) println(c^n) end

function imprimir_painel(fab, lim, fator)
    println()
    sep("═")
    println("  BALL CORPORATION — ANÁLISE DE SENSIBILIDADE")
    println("  Rodado em: $(Dates.format(now(), "dd/mm/yyyy HH:MM"))")
    sep("─")
    println("  CONFIGURAÇÃO DO PAINEL:")
    println("    Fator de demanda  : $(fator)x  $(fator > 1.0 ? "($(round(Int, fator*100))% da demanda original)" : "(normal)")")
    println("    Fábrica quebrada  : $fab")
    println("    Limite caminhões  : $lim caminhões/dia/planta")
    sep("═")
end

function imprimir_tabela(resultados)
    println()
    @printf("  %-9s  %-14s  %-14s  %-14s  %-14s  %-14s  %-11s\n",
        "Cenário", "Custo Prod.", "Custo Estq.", "Custo Log.", "Custo Atraso", "Multa Cancel.", "Atendimento")
    sep()
    for r in resultados
        if r.status == "OPTIMAL"
            @printf("  ocup_%-4s  %s  %s  %s  %s  %s  %9.2f%%\n",
                r.cenario,
                fmt_real(r.custo_producao),
                fmt_real(r.custo_estoque),
                fmt_real(r.custo_logistica),
                fmt_real(r.custo_atraso),
                fmt_real(r.custo_multa_w),
                r.taxa_atendimento)
        else
            @printf("  ocup_%-4s  %-14s  %-14s  %-14s  %-14s  %-14s  [%s]\n",
                r.cenario, "---","---","---","---","---", r.status)
        end
    end
    sep()

    # Resumo
    opts = filter(r -> r.status == "OPTIMAL", resultados)
    if !isempty(opts)
        println()
        println("  RESUMO:")
        @printf("    Cenários resolvidos    : %d / %d\n", length(opts), length(resultados))

        idx_min = argmin([isnan(r.custo_total) ? Inf  : r.custo_total for r in resultados])
        idx_max = argmax([isnan(r.custo_total) ? -Inf : r.custo_total for r in resultados])
        
        # Totalizando as falhas de serviço
        total_cancelado = sum(r.nao_atendido for r in opts)
        total_atrasado  = sum(r.latas_atrasadas for r in opts)

        @printf("    Custo total mínimo     : %s  (ocupacao_%s)\n",
            fmt_real(minimum(r.custo_total for r in opts)),
            resultados[idx_min].cenario)
        @printf("    Custo total máximo     : %s  (ocupacao_%s)\n",
            fmt_real(maximum(r.custo_total for r in opts)),
            resultados[idx_max].cenario)
        @printf("    Taxa de Atendimento    : %.2f%% (min) — %.2f%% (max)\n",
            minimum(r.taxa_atendimento for r in opts),
            maximum(r.taxa_atendimento for r in opts))
        
        println("    Análise de Nível de Serviço:")
        @printf("      ↳ Latas Canceladas   : %.0f un\n", total_cancelado)
        @printf("      ↳ Latas Atrasadas    : %.0f un\n", total_atrasado)
    end
    println()
end

# ==============================================================================
# EXECUÇÃO
# ==============================================================================

df_log = CSV.read(caminho_base * "input_logistic_costs_artificial.csv", DataFrame)

imprimir_painel(fabrica_quebrada, limite_caminhoes, fator_demanda)

println("\n  Resolvendo $(length(CENARIOS)) cenários...\n")
resultados = []
for (idx, cenario) in enumerate(CENARIOS)
    progresso(idx, length(CENARIOS), "ocupacao_$cenario")
    r = resolver_cenario(cenario, fabrica_quebrada, limite_caminhoes, fator_demanda, df_log)
    push!(resultados, r)
end

imprimir_tabela(resultados)

# ── Exporta CSV ──────────────────────────────────────────────────────────────
df_saida = DataFrame(resultados)
df_saida.fabrica_quebrada .= fabrica_quebrada
df_saida.limite_caminhoes .= limite_caminhoes
df_saida.fator_demanda    .= fator_demanda

timestamp    = Dates.format(now(), "yyyymmdd_HHMM")
nome_arquivo = "resultados_$(fabrica_quebrada)_cam$(limite_caminhoes)_fator$(fator_demanda)_$(timestamp).csv"
CSV.write(caminho_base * nome_arquivo, df_saida)
println("  Resultados salvos em: $nome_arquivo\n")