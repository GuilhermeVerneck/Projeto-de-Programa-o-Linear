using JuMP
using Gurobi
using CSV
using DataFrames
using Printf
using Dates

# ==============================================================================
#                            PAINEL DE CONTROLE
# ==============================================================================

fabrica_quebrada = "Nenhuma"   # "Nenhuma" | "Extrema" | "Jacarei" | qualquer planta
limite_caminhoes = 80          # 80 (normal) | 40 (greve parcial) | 10 (colapso logístico)
fator_demanda    = 1.0         # 1.0 (normal) | 1.5 (choque +50%) | 2.0 (dobra a demanda)

# --- PARÂMETROS ESTOCÁSTICOS DO MUNDO REAL ---
fator_oee      = 0.85  # <--- NOVO: As máquinas rodam a 85% da eficiência (absorve micro-paradas)
dias_seguranca = 1.0   # <--- NOVO: Meta de manter 1 dia de demanda média sempre no armazém

# ==============================================================================
# AMBIENTE GUROBI
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

function parse_br_float(val)
    ismissing(val) || val == "" && return 0.0
    return parse(Float64, replace(String(val), "," => "."))
end

function extrair_dia(data_str)
    return parse(Int, string(data_str)[9:10])
end

function progresso(atual, total, label="")
    pct   = round(Int, atual / total * 100)
    blocos = round(Int, pct / 5)
    barra  = "█"^blocos * "░"^(20 - blocos)
    print("\r  [$barra] $pct%  $label")
    atual == total && println()
end

function fmt_real(x::Real)
    isnan(x) && return "           ---"
    s = @sprintf("%.2f", abs(x))
    partes = split(s, ".")
    inteiro = partes[1]
    decimal = partes[2]
    
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

    # ── Leitura ──────────────────────────────────────────────────────────────
    df_need  = CSV.read(caminho_pasta * "input_production_need_artificial.csv",    DataFrame)
    df_rate  = CSV.read(caminho_pasta * "input_production_rate_artificial.csv",    DataFrame)
    df_costs = CSV.read(caminho_pasta * "input_sku_costs_artificial.csv",          DataFrame)
    df_limit = CSV.read(caminho_pasta * "input_line_storage_limit_artificial.csv", DataFrame)

    df_need.prod_need = parse_br_float.(df_need.prod_need)

    # ── Conjuntos ────────────────────────────────────────────────────────────
    I   = unique(df_need.product_id)
    P   = unique(df_rate.plant)
    T   = 1:15
    L_p = Dict(p => unique(df_rate[df_rate.plant .== p, :production_line]) for p in P)

    # ── Parâmetros ───────────────────────────────────────────────────────────
    k     = Dict((r.product_id, r.plant, r.production_line) => r.production_cost  for r in eachrow(df_costs))
    v     = Dict((r.product_id, r.plant, r.production_line) => r.inventory_cost   for r in eachrow(df_costs))
    ct    = Dict((r.origem, r.destino)                       => r.custo_total_frete for r in eachrow(df_log))
    e_max = Dict((r.plant, r.production_line)                => r.storage_limit    for r in eachrow(df_limit))

    eta = Dict((i,p,l,t) => 0.0 for i in I for p in P for l in L_p[p] for t in T)

    for r in eachrow(df_need)
        t     = extrair_dia(string(r.deadline))
        chave = (r.product_id, r.plant, r.production_line, t)
        haskey(eta, chave) && (eta[chave] += r.prod_need)
    end

    r_taxa = Dict((p,l,t) => 0.0 for p in P for l in L_p[p] for t in T)
    for r in eachrow(df_rate)
        t = extrair_dia(string(r.ref_date))
        r_taxa[(r.plant, r.production_line, t)] = r.rate
    end
        
    formatos_da_linha = Dict(r.production_line => r.sku_size_shape for r in eachrow(df_rate))

    C = Set((r.product_id, r.plant, r.production_line) for r in eachrow(df_need)
        if haskey(formatos_da_linha, r.production_line) && r.sku_size_shape == formatos_da_linha[r.production_line]
    )

    # <--- NOVO: Calcula a Demanda Média Diária para o Estoque de Segurança --->
    demanda_media = Dict((i,p,l) => sum(get(eta, (i,p,l,t), 0.0) for t in T) / 15.0 for i in I for p in P for l in L_p[p])

    # ── Modelo ───────────────────────────────────────────────────────────────
    modelo = Model(() -> Gurobi.Optimizer(GRB_ENV))
    set_silent(modelo)

    @variable(modelo, x[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, e[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, a[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, f[i in I, o in P, d in P, t in T; o != d] >= 0)
    @variable(modelo, g[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, s[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, w[i in I, p in P, l in L_p[p], t in T] >= 0)
    
    # <--- NOVA VARIÁVEL: Mede o quanto a fábrica ficou abaixo da meta de segurança --->
    @variable(modelo, falta_ss[i in I, p in P, l in L_p[p], t in T] >= 0) 

    # Função objetivo
    @objective(modelo, Min,
        sum(k[i,p,l] * x[i,p,l,t]
            for p in P, l in L_p[p], i in I, t in T if (i,p,l) ∈ C) +
        sum(v[i,p,l] * e[i,p,l,t]
            for p in P, l in L_p[p], i in I, t in T if haskey(v,(i,p,l))) +
        sum(ct[o,d] * (f[i,o,d,t] / 200_000)
            for i in I, o in P, d in P, t in T if o != d) +
        sum(1_000_000 * w[i,p,l,t] 
            for p in P, l in L_p[p], i in I, t in T) +
        # <--- NOVA MULTA LEVE: Paga R$ 5,00 por lata abaixo do estoque de segurança --->
        sum(5.0 * falta_ss[i,p,l,t] 
            for p in P, l in L_p[p], i in I, t in T)
    )

    # R1 – Limite de armazenagem
    @constraint(modelo, R1[p in P, l in L_p[p], t in T],
        sum(e[i,p,l,t] for i in I) <= e_max[(p,l)]
    )

    # R2 – Balanço de estoque (estoque inicial = 0)
    @constraint(modelo, R2[i in I, p in P, l in L_p[p], t in T],
    e[i,p,l,t] == (t == 1 ? 0.0 : e[i,p,l,t-1]) +
                  x[i,p,l,t] + g[i,p,l,t] - s[i,p,l,t] - a[i,p,l,t]
    )

    # R3 – Atendimento à demanda (w absorve o que não consegue entregar)
    @constraint(modelo, R3[i in I, p in P, l in L_p[p], t in T],
        a[i,p,l,t] + w[i,p,l,t] == eta[(i,p,l,t)] * fator_demanda
    )

    # R4 – Capacidade produtiva (AGORA PENALIZADA PELO OEE)
    @constraint(modelo, R4[p in P, l in L_p[p], t in T],
        sum(x[i,p,l,t] / (r_taxa[(p,l,t)] * fator_oee) # <--- MULTIPLICADOR AQUI --->
        for i in I if (i,p,l) ∈ C && r_taxa[(p,l,t)] > 0) <=
        (p == fabrica_quebrada ? 0.0 : 24.0)
    )

    # R5 – Capacidade logística de saída por planta
    @constraint(modelo, R5[p in P, t in T],
        sum(f[i,p,d,t] / 200_000 for i in I, d in P if d != p) <= limite_caminhoes
    )

    # R6 – Redistribuição interna (doca de entrada)
    @constraint(modelo, R6[i in I, p in P, t in T],
        sum(g[i,p,l,t] for l in L_p[p]) == sum(f[i,o,p,t] for o in P if o != p)
    )

    # R7 - Doca de saída 
    @constraint(modelo, R7[i in I, p in P, t in T],
        sum(s[i,p,l,t] for l in L_p[p]) == sum(f[i,p,d,t] for d in P if d != p)
    )

    # R8 – Capabilidade de formato
    @constraint(modelo, R8[i in I, p in P, l in L_p[p], t in T; (i,p,l) ∉ C], 
        x[i,p,l,t] == 0
    )

    # <--- NOVA RESTRIÇÃO: R10 (Safety Stock Flexível) --->
    @constraint(modelo, R10[i in I, p in P, l in L_p[p], t in T; (i,p,l) ∈ C],
        e[i,p,l,t] + falta_ss[i,p,l,t] >= demanda_media[(i,p,l)] * dias_seguranca
    )

    # ── Resolve ──────────────────────────────────────────────────────────────
    optimize!(modelo)
    status = termination_status(modelo)

    if status ∉ (MOI.OPTIMAL, MOI.FEASIBLE_POINT)
        empty!(modelo); GC.gc()
        return (cenario=cenario, status=string(status), custo_producao=NaN, custo_estoque=NaN, custo_logistica=NaN, custo_penalidade=NaN, custo_risco=NaN, custo_total=NaN, demanda_total=NaN, atendido=NaN, nao_atendido=NaN, taxa_atendimento=NaN, caminhoes=NaN)
    end
          
    # ── Métricas ─────────────────────────────────────────────────────────────
    total_w = sum(value(w[i,p,l,t]) for p in P for l in L_p[p] for i in I for t in T)
    total_a = sum(value(a[i,p,l,t]) for p in P for l in L_p[p] for i in I for t in T)
    total_fss = sum(value(falta_ss[i,p,l,t]) for p in P for l in L_p[p] for i in I for t in T)
    
    total_demanda = total_a + total_w
    custo_pen = total_w * 1_000_000
    custo_risco = total_fss * 5.0 # <--- CAPTURA O CUSTO DA FALTA DE ESTOQUE SEGURO
    
    custo_prod = sum(k[i,p,l] * value(x[i,p,l,t]) for p in P for l in L_p[p] for i in I for t in T if (i,p,l) ∈ C)
    custo_est = sum(v[i,p,l] * value(e[i,p,l,t]) for p in P for l in L_p[p] for i in I for t in T if haskey(v,(i,p,l)))
    custo_log  = sum(ct[o,d] * value(f[i,o,d,t]) / 200_000 for i in I for o in P for d in P for t in T if o != d)
    caminhoes  = sum(value(f[i,o,d,t]) / 200_000 for i in I for o in P for d in P for t in T if o != d)
    
    taxa = total_demanda > 0 ? (total_a / total_demanda) * 100 : 100.0
    obj_val = objective_value(modelo)

    empty!(modelo)
    GC.gc()

    return (
        cenario          = cenario,
        status           = "OPTIMAL",
        custo_producao   = round(custo_prod, digits=2),
        custo_estoque    = round(custo_est,  digits=2),
        custo_logistica  = round(custo_log,  digits=2),
        custo_penalidade = round(custo_pen,  digits=2),
        custo_risco      = round(custo_risco,digits=2), # <--- NOVO
        custo_total      = round(obj_val,    digits=2),
        demanda_total    = round(total_demanda, digits=0),
        atendido         = round(total_a,   digits=0),
        nao_atendido     = round(total_w,   digits=0),
        taxa_atendimento = round(taxa,       digits=2),
        caminhoes        = round(caminhoes,  digits=1),
    )
end

# ==============================================================================
# OUTPUT NO TERMINAL
# ==============================================================================

function sep(c="─", n=115) println(c^n) end

function imprimir_painel(fab, lim, fator, oee)
    println()
    sep("═")
    println("  BALL CORPORATION — ANÁLISE DE SENSIBILIDADE ESTOCÁSTICA")
    println("  Rodado em: $(Dates.format(now(), "dd/mm/yyyy HH:MM"))")
    sep("─")
    println("  CONFIGURAÇÃO DO PAINEL:")
    println("    Fator de demanda  : $(fator)x")
    println("    Eficiência (OEE)  : $(round(Int, oee*100))% da capacidade nominal")
    println("    Fábrica quebrada  : $fab")
    println("    Limite caminhões  : $lim caminhões/dia/planta")
    sep("═")
end

function imprimir_tabela(resultados)
    println()
    @printf("  %-9s  %-13s  %-13s  %-13s  %-13s  %-13s  %-10s\n",
        "Cenário", "Custo Prod.", "Custo Estq.", "Custo Log.", "Risco (S.S)", "Multa \$ (w)", "Atendimento")
    sep()
    for r in resultados
        if r.status == "OPTIMAL"
            @printf("  ocup_%-4s  %13.2f  %13.2f  %13.2f  %13.2f  %13.2f  %9.2f%%\n",
                r.cenario,
                r.custo_producao, r.custo_estoque, r.custo_logistica, 
                r.custo_risco, r.custo_penalidade, r.taxa_atendimento)
        else
            @printf("  ocup_%-4s  [%s]\n", r.cenario, r.status)
        end
    end
    sep()
end

# ==============================================================================
# EXECUÇÃO
# ==============================================================================

df_log = CSV.read(caminho_base * "input_logistic_costs_artificial.csv", DataFrame)

imprimir_painel(fabrica_quebrada, limite_caminhoes, fator_demanda, fator_oee)

println("\n  Resolvendo $(length(CENARIOS)) cenários...\n")
resultados = []
for (idx, cenario) in enumerate(CENARIOS)
    progresso(idx, length(CENARIOS), "ocupacao_$cenario")
    r = resolver_cenario(cenario, fabrica_quebrada, limite_caminhoes, fator_demanda, df_log)
    push!(resultados, r)
end

imprimir_tabela(resultados)