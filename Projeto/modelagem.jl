using JuMP
using Gurobi
using CSV
using DataFrames
using Printf
using Dates

# ==============================================================================
# ██████████████████████████████████████████████████████████████████████████████
#                          PAINEL DE CONTROLE
#  Altere aqui antes de rodar. O script vai rodar todos os 21 cenários
#  (ocupacao_50 até ocupacao_150) com essa configuração fixa.
# ██████████████████████████████████████████████████████████████████████████████
# ==============================================================================

fabrica_quebrada = "Nenhuma"   # "Nenhuma" | "Extrema" | "Jacarei" | qualquer planta
limite_caminhoes = 80          # 80 (normal) | 40 (greve parcial) | 10 (colapso logístico)
fator_demanda    = 1.0         # 1.0 (normal) | 1.5 (+50%) | 2.0 (dobra) | 3.0 (caos)

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
function parse_br_float(val)
    ismissing(val) || val == "" && return 0.0
    return parse(Float64, replace(String(val), "," => "."))
end

# Extrai o dia de uma string de data (ex: "2024-01-05" -> 5)
function extrair_dia(data_str)
    return parse(Int, string(data_str)[9:10])
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
    # Insere ponto a cada 3 dígitos da direita
    n = length(inteiro)
    com_pontos = join([inteiro[max(1,i-2):i] for i in 3:3:n+2 if i-2 <= n], ".")
    # Recalcula sem erro de borda
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

    # Conversão de formato brasileiro para todos os campos numéricos relevantes
    df_need.prod_need = parse_br_float.(df_need.prod_need)

    # ── Conjuntos ────────────────────────────────────────────────────────────
    I   = unique(df_need.product_id)
    P   = unique(df_rate.plant)
    T   = 1:15
    L_p = Dict(p => unique(df_rate[df_rate.plant .== p, :production_line]) for p in P)

    # ── Parâmetros ───────────────────────────────────────────────────────────
    k     = Dict((r.product_id, r.plant, r.production_line) => parse_br_float(r.production_cost)
                 for r in eachrow(df_costs))
    v     = Dict((r.product_id, r.plant, r.production_line) => parse_br_float(r.inventory_cost)
                 for r in eachrow(df_costs))
    ct    = Dict((r.origem, r.destino) => parse_br_float(r.custo_total_frete)
                 for r in eachrow(df_log))
    e_max = Dict((r.plant, r.production_line) => parse_br_float(r.storage_limit)
                 for r in eachrow(df_limit))

    # Demanda: inicializa com 0 para cobrir combinações sem pedido no CSV
    eta = Dict{Tuple{Any,Any,Any,Int}, Float64}()
    for i in I, p in P, l in L_p[p], t in T
        eta[(i, p, l, t)] = 0.0
    end
    for r in eachrow(df_need)
        t     = extrair_dia(string(r.deadline))
        chave = (r.product_id, r.plant, r.production_line, t)
        haskey(eta, chave) && (eta[chave] += r.prod_need)
    end

    # Taxa de produção: inicializa com 0 (ausência = linha não opera)
    r_taxa = Dict{Tuple{Any,Any,Int}, Float64}()
    for p in P, l in L_p[p], t in T
        r_taxa[(p, l, t)] = 0.0
    end
    for r in eachrow(df_rate)
        t = extrair_dia(string(r.ref_date))
        r_taxa[(r.plant, r.production_line, t)] = parse_br_float(r.rate)
    end

    # Conjunto C: triplas (i, p, l) onde o formato do SKU bate com o formato da linha
    formatos_da_linha = Dict(r.production_line => r.sku_size_shape for r in eachrow(df_rate))
    C = Set(
        (r.product_id, r.plant, r.production_line)
        for r in eachrow(df_need)
        if haskey(formatos_da_linha, r.production_line) &&
           r.sku_size_shape == formatos_da_linha[r.production_line]
    )

    # ── Modelo ───────────────────────────────────────────────────────────────
    modelo = Model(Gurobi.Optimizer)
    set_silent(modelo)

    @variable(modelo, x[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, e[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, a[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, f[i in I, o in P, d in P, t in T; o != d] >= 0)
    @variable(modelo, g[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, s[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, w[i in I, p in P, l in L_p[p], t in T] >= 0)

    # ── Função objetivo ──────────────────────────────────────────────────────
    @objective(modelo, Min,
        sum(k[(i,p,l)] * x[i,p,l,t]
            for p in P, l in L_p[p], i in I, t in T
            if (i,p,l) ∈ C) +
        sum(v[(i,p,l)] * e[i,p,l,t]
            for p in P, l in L_p[p], i in I, t in T
            if haskey(v,(i,p,l))) +
        sum(ct[(o,d)] * (f[i,o,d,t] / 200_000)
            for i in I, o in P, d in P, t in T if o != d) +
        sum(1_000_000 * w[i,p,l,t]
            for p in P, l in L_p[p], i in I, t in T)
    )

    # ── Restrições ───────────────────────────────────────────────────────────

    # R1: limite de armazenagem (espaço compartilhado entre SKUs)
    @constraint(modelo, R1[p in P, l in L_p[p], t in T],
        sum(e[i,p,l,t] for i in I) <= e_max[(p,l)]
    )

    # R2: balanço de estoque (e[t=0] = 0 via operador ternário)
    @constraint(modelo, R2[i in I, p in P, l in L_p[p], t in T],
        e[i,p,l,t] == (t == 1 ? 0.0 : e[i,p,l,t-1]) +
                      x[i,p,l,t] + g[i,p,l,t] - s[i,p,l,t] - a[i,p,l,t]
    )

    # R3: atendimento à demanda com fator de escalonamento
    @constraint(modelo, R3[i in I, p in P, l in L_p[p], t in T],
        a[i,p,l,t] + w[i,p,l,t] == eta[(i,p,l,t)] * fator_demanda
    )

    # R4: capacidade produtiva (planta quebrada => limite 0h)
    @constraint(modelo, R4[p in P, l in L_p[p], t in T],
        sum(x[i,p,l,t] / r_taxa[(p,l,t)]
            for i in I if (i,p,l) ∈ C && r_taxa[(p,l,t)] > 0) <=
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

    status ∉ (MOI.OPTIMAL, MOI.FEASIBLE_POINT) && return (
        cenario          = cenario,
        status           = string(status),
        custo_producao   = NaN, custo_estoque    = NaN,
        custo_logistica  = NaN, custo_penalidade = NaN,
        custo_total      = NaN, demanda_total    = NaN,
        atendido         = NaN, nao_atendido     = NaN,
        taxa_atendimento = NaN, caminhoes        = NaN,
    )

    # ── Métricas ─────────────────────────────────────────────────────────────
    total_w    = sum(value(w[i,p,l,t]) for p in P, l in L_p[p], i in I, t in T)
    total_a    = sum(value(a[i,p,l,t]) for p in P, l in L_p[p], i in I, t in T)
    custo_pen  = total_w * 1_000_000
    custo_prod = sum(k[(i,p,l)] * value(x[i,p,l,t])
                     for p in P, l in L_p[p], i in I, t in T if (i,p,l) ∈ C)
    custo_est  = sum(v[(i,p,l)] * value(e[i,p,l,t])
                     for p in P, l in L_p[p], i in I, t in T if haskey(v,(i,p,l)))
    custo_log  = sum(ct[(o,d)] * value(f[i,o,d,t]) / 200_000
                     for i in I, o in P, d in P, t in T if o != d)
    caminhoes  = sum(value(f[i,o,d,t]) / 200_000
                     for i in I, o in P, d in P, t in T if o != d)
    taxa       = (total_a + total_w) > 0 ? total_a / (total_a + total_w) * 100 : 100.0

    return (
        cenario          = cenario,
        status           = "OPTIMAL",
        custo_producao   = round(custo_prod,              digits=2),
        custo_estoque    = round(custo_est,               digits=2),
        custo_logistica  = round(custo_log,               digits=2),
        custo_penalidade = round(custo_pen,               digits=2),
        custo_total      = round(objective_value(modelo), digits=2),
        demanda_total    = round(total_a + total_w,       digits=0),
        atendido         = round(total_a,                 digits=0),
        nao_atendido     = round(total_w,                 digits=0),
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
    @printf("  %-9s  %-14s  %-14s  %-14s  %-14s  %-11s  %-9s\n",
        "Cenário", "Custo Prod.", "Custo Estq.", "Custo Log.", "Custo Multa",
        "Atendimento", "Caminhões")
    sep()
    for r in resultados
        if r.status == "OPTIMAL"
            @printf("  ocup_%-4s  %s  %s  %s  %s  %9.2f%%  %9.1f\n",
                r.cenario,
                fmt_real(r.custo_producao),
                fmt_real(r.custo_estoque),
                fmt_real(r.custo_logistica),
                fmt_real(r.custo_penalidade),
                r.taxa_atendimento,
                r.caminhoes)
        else
            @printf("  ocup_%-4s  %-14s  %-14s  %-14s  %-14s  %-11s  %-9s  [%s]\n",
                r.cenario, "---","---","---","---","---","---", r.status)
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
        @printf("    Custo total mínimo     : %s  (ocupacao_%s)\n",
            fmt_real(minimum(r.custo_total for r in opts)),
            resultados[idx_min].cenario)
        @printf("    Custo total máximo     : %s  (ocupacao_%s)\n",
            fmt_real(maximum(r.custo_total for r in opts)),
            resultados[idx_max].cenario)
        @printf("    Taxa de atendimento    : %.2f%% (min) — %.2f%% (max)\n",
            minimum(r.taxa_atendimento for r in opts),
            maximum(r.taxa_atendimento for r in opts))
        demanda_perdida = sum(r.nao_atendido for r in opts)
        demanda_perdida > 0 &&
            @printf("    ⚠ Demanda não atendida : %.0f latas no total\n", demanda_perdida)
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