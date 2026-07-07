using JuMP
using Gurobi
using CSV
using DataFrames
using Printf
using Dates

# ==============================================================================
# CONFIGURAÇÃO
#
# Struct única que centraliza o painel de controle, os caminhos de entrada/saída,
# a penalidade Big-M, a convenção de unidades e as constantes do modelo.
# ==============================================================================

Base.@kwdef struct Config
    # Painel de sensibilidade
    fabrica_quebrada::String  = "Nenhuma"   # "Nenhuma" | "Extrema" | "Jacarei" | qualquer planta
    limite_caminhoes::Int     = 80          # 80 (normal) | 40 (greve parcial) | 10 (colapso)
    fator_demanda::Float64    = 1.0         # 1.0 (normal) | 1.5 | 2.0 | 3.0 (choques de demanda)
    fator_oee::Float64        = 1.0         # eficiência operacional das máquinas (OEE)

    # Caminhos (resolvidos relativos ao diretório do projeto)
    input_dir::String         = joinpath(@__DIR__, "..", "Instancias")
    output_dir::String        = joinpath(@__DIR__, "..", "saidas")

    # Penalidade Big-M para demanda não atendida (definida uma única vez)
    big_m::Float64            = 1_000_000.0

    # Unidades: a unidade interna do modelo é a LATA. Conversão: 1 milheiro = 1000 latas.
    unidade_interna::Symbol   = :lata
    latas_por_milheiro::Int   = 1_000
    unidade_relatorio::Symbol = :lata          # :lata | :milheiro

    # Variáveis de doca: false = formulação com s/g
    simplificar_docas::Bool   = false

    # Constantes do modelo
    latas_por_caminhao::Int   = 200_000        # capacidade de um caminhão (latas)
    horas_dia::Float64        = 24.0           # janela diária de produção
    dias::UnitRange{Int}      = 1:15           # horizonte de planejamento (dias)

    # Custo de estoque usado quando a combinação SKU/planta/linha não tem custo tabulado
    custo_estoque_padrao::Float64 = 0.0
end

# Valida o diretório de entrada e cria o de saída se necessário.
function resolve_paths(cfg::Config)
    if !isdir(cfg.input_dir)
        error("Diretório de entrada não encontrado: \"$(cfg.input_dir)\". " *
              "Ajuste o campo `input_dir` da Config.")
    end

    if !isdir(cfg.output_dir)
        try
            mkpath(cfg.output_dir)
        catch err
            error("Não foi possível criar o diretório de saída \"$(cfg.output_dir)\": $(err)")
        end
    end

    return (; input_dir = cfg.input_dir, output_dir = cfg.output_dir)
end

# ==============================================================================
# PAINEL DE CONTROLE
# Altere aqui antes de rodar. O script roda todos os 21 cenários
# (ocupacao_50 até ocupacao_150) com essa configuração fixa.
# ==============================================================================

fabrica_quebrada = "Nenhuma"   # "Nenhuma" | "Extrema" | "Jacarei" | qualquer planta
limite_caminhoes = 80          # 80 (normal) | 40 (greve parcial) | 10 (colapso logístico)
fator_demanda    = 1.0         # 1.0 (normal) | 1.5 | 2.0 | 3.0
                               # Dica: fator_demanda=2.0 + ocupacao_100 ≈ 200% de ocupação
fator_oee        = 1.0         # eficiência das máquinas (1.0 = capacidade nominal)

const GRB_ENV    = Gurobi.Env()
const CFG_PADRAO = Config()

CENARIOS = ["50","55","60","65","70","75","80","85","90",
            "95","100","105","110","115","120","125","130",
            "135","140","145","150"]

# ==============================================================================
# FUNÇÕES AUXILIARES
# ==============================================================================

# Converte um número no padrão brasileiro (vírgula decimal) para Float64.
# Valores ausentes ou vazios viram 0.0; valores malformados disparam erro.
function parse_br_float(val)
    if ismissing(val) || val == ""
        return 0.0
    end
    s = replace(String(val), "," => ".")
    parsed = tryparse(Float64, s)
    if parsed === nothing
        error("parse_br_float: valor malformado '$(val)'")
    end
    return parsed
end

# Caminho da pasta de um cenário e de um arquivo dentro dela.
scenario_dir(cfg::Config, cenario::AbstractString) =
    joinpath(cfg.input_dir, "ocupacao_" * cenario)

input_path(cfg::Config, cenario::AbstractString, filename::AbstractString) =
    joinpath(scenario_dir(cfg, cenario), filename)

# Extrai o dia (1..15) de uma data no formato "YYYY-MM-DD...".
function extrair_dia(data_str)
    return parse(Int, string(data_str)[9:10])
end

# Custo de estoque da combinação (i,p,l): usa o tabulado ou o padrão da Config.
inventory_cost(cfg::Config, v::Dict, i, p, l) =
    get(v, (i, p, l), cfg.custo_estoque_padrao)

# Converte um valor em latas para a unidade de relatório, devolvendo (valor, rótulo).
function convert_to_report_unit(cfg::Config, value_cans::Real)
    if cfg.unidade_relatorio == :milheiro
        return (value_cans / cfg.latas_por_milheiro, "milheiro")
    else
        return (Float64(value_cans), string(cfg.unidade_relatorio))
    end
end

# Barra de progresso simples no terminal.
function progresso(atual, total, label="")
    pct    = round(Int, atual / total * 100)
    blocos = round(Int, pct / 5)
    barra  = "█"^blocos * "░"^(20 - blocos)
    print("\r  [$barra] $pct%  ($atual/$total)  $label          ")
    flush(stdout)
    atual == total && println()
end

# ==============================================================================
# LEITURA DOS DADOS DE UM CENÁRIO
# Lê os quatro CSVs por cenário e aplica parse_br_float na coluna de demanda.
# ==============================================================================

function load_scenario_inputs(cfg::Config, cenario::AbstractString)
    df_need  = CSV.read(input_path(cfg, cenario, "input_production_need_artificial.csv"),    DataFrame)
    df_rate  = CSV.read(input_path(cfg, cenario, "input_production_rate_artificial.csv"),    DataFrame)
    df_costs = CSV.read(input_path(cfg, cenario, "input_sku_costs_artificial.csv"),          DataFrame)
    df_limit = CSV.read(input_path(cfg, cenario, "input_line_storage_limit_artificial.csv"), DataFrame)

    df_need.prod_need = parse_br_float.(df_need.prod_need)

    return (df_need, df_rate, df_costs, df_limit)
end

# ==============================================================================
# FUNÇÃO OBJETIVO E MÉTRICAS PÓS-SOLUÇÃO
# ==============================================================================

# Monta a função objetivo (Min): produção + estoque + frete + multa Big-M.
function build_objective!(modelo, cfg::Config, sets, params, vars)
    (; I, P, T, L_p, C) = sets
    (; k, v, ct)        = params
    (; x, e, f, w)      = vars

    @objective(modelo, Min,
        sum(k[i,p,l] * x[i,p,l,t]
            for p in P, l in L_p[p], i in I, t in T if (i,p,l) ∈ C) +
        sum(inventory_cost(cfg, v, i, p, l) * e[i,p,l,t]
            for p in P, l in L_p[p], i in I, t in T) +
        sum(ct[o,d] * (f[i,o,d,t] / 200_000)
            for i in I, o in P, d in P, t in T if o != d) +
        sum(cfg.big_m * w[i,p,l,t]
            for p in P, l in L_p[p], i in I, t in T)
    )
end

# Calcula os componentes de custo e estatísticas de demanda após o solve.
function compute_metrics(cfg::Config, modelo, sets, params, vars)
    (; I, P, T, L_p, C) = sets
    (; k, v, ct)        = params
    (; x, e, a, f, w)   = vars

    total_w = sum(value(w[i,p,l,t]) for p in P for l in L_p[p] for i in I for t in T)
    total_a = sum(value(a[i,p,l,t]) for p in P for l in L_p[p] for i in I for t in T)
    total_demanda = total_a + total_w

    custo_pen  = total_w * cfg.big_m
    custo_prod = sum(k[i,p,l] * value(x[i,p,l,t])
                 for p in P for l in L_p[p] for i in I for t in T if (i,p,l) ∈ C)
    custo_est  = sum(inventory_cost(cfg, v, i, p, l) * value(e[i,p,l,t])
                 for p in P for l in L_p[p] for i in I for t in T)
    custo_log  = sum(ct[o,d] * value(f[i,o,d,t]) / 200_000
                 for i in I for o in P for d in P for t in T if o != d)
    caminhoes  = sum(value(f[i,o,d,t]) / 200_000
                 for i in I for o in P for d in P for t in T if o != d)
    taxa       = total_demanda > 0 ? (total_a / total_demanda) * 100 : 100.0
    obj_val    = objective_value(modelo)

    return (
        custo_producao   = custo_prod,
        custo_estoque    = custo_est,
        custo_logistica  = custo_log,
        custo_penalidade = custo_pen,
        custo_total      = obj_val,
        demanda_total    = total_demanda,
        atendido         = total_a,
        nao_atendido     = total_w,
        taxa_atendimento = taxa,
        caminhoes        = caminhoes,
    )
end

# ==============================================================================
# PREÇOS DE SOMBRA (VARIÁVEIS DUAIS)
# ==============================================================================

# Extrai os duais das restrições R1 (armazenagem), R3 (demanda) e R4 (horas).
# Retorna nothing quando o problema não tem solução dual disponível.
function extract_duals(cfg::Config, modelo, cenario, sets, cons, vars)
    if dual_status(modelo) != MOI.FEASIBLE_POINT
        @warn "Cenário '$cenario' sem solução dual (dual_status = $(dual_status(modelo))). Duals ignorados."
        return nothing
    end

    (; I, P, T, L_p) = sets
    (; w) = vars
    tol = 1e-6

    # μ: valor marginal de +1 hora-máquina (R4)
    mu_rows = [(plant=p, linha=l, periodo=t, mu_hora_maquina=shadow_price(cons.R4[p,l,t]))
               for p in P for l in L_p[p] for t in T]

    # γ: valor marginal de +1 unidade de armazenagem (R1)
    gamma_rows = [(plant=p, linha=l, periodo=t, gamma_armazenagem=shadow_price(cons.R1[p,l,t]))
                  for p in P for l in L_p[p] for t in T]

    # π: custo marginal de atender demanda (R3); marca saturado quando há w > tol
    pi_rows = [(produto=i, plant=p, linha=l, periodo=t,
                pi_demanda=shadow_price(cons.R3[i,p,l,t]),
                saturado=value(w[i,p,l,t]) > tol)
               for i in I for p in P for l in L_p[p] for t in T]

    return (; mu_rows, gamma_rows, pi_rows)
end

# Persiste dois CSVs por cenário em output_dir: duais de capacidade e de demanda.
# Valores negativos de μ são preservados (capacidade extra aumentaria o custo).
function report_duals(cfg::Config, cenario::AbstractString, duals)
    _, unidade_label = convert_to_report_unit(cfg, 0.0)

    gamma_lookup = Dict((r.plant, r.linha, r.periodo) => r.gamma_armazenagem
                        for r in duals.gamma_rows)

    cap_rows = [(
        cenario            = cenario,
        plant              = r.plant,
        linha              = r.linha,
        periodo            = r.periodo,
        mu_hora_maquina    = r.mu_hora_maquina,
        gamma_armazenagem  = get(gamma_lookup, (r.plant, r.linha, r.periodo), 0.0),
        unidade            = unidade_label,
    ) for r in duals.mu_rows]

    df_cap = DataFrame(cap_rows)
    path_cap = joinpath(cfg.output_dir, "duals_capacidade_ocupacao_$(cenario).csv")
    CSV.write(path_cap, df_cap)

    dem_rows = [(
        cenario    = cenario,
        produto    = r.produto,
        plant      = r.plant,
        linha      = r.linha,
        periodo    = r.periodo,
        pi_demanda = r.pi_demanda,
        saturado   = r.saturado,
        unidade    = unidade_label,
    ) for r in duals.pi_rows]

    df_dem = DataFrame(dem_rows)
    path_dem = joinpath(cfg.output_dir, "duals_demanda_ocupacao_$(cenario).csv")
    CSV.write(path_dem, df_dem)

    return (path_cap, path_dem)
end

# ==============================================================================
# MONTAGEM DO MODELO
# ==============================================================================

# Monta os conjuntos de índices e os dicionários de parâmetros a partir dos CSVs.
# Retorna (sets, params, e_max).
function build_sets_and_params(cfg::Config, df_need, df_rate, df_costs, df_limit, df_log)
    # Conjuntos
    I   = unique(df_need.product_id)
    P   = unique(df_rate.plant)
    T   = cfg.dias
    L_p = Dict(p => unique(df_rate[df_rate.plant .== p, :production_line]) for p in P)

    # Parâmetros
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

    # Formato que cada linha consegue produzir (vem do df_rate)
    formatos_da_linha = Dict(
        r.production_line => r.sku_size_shape
        for r in eachrow(df_rate)
    )

    # C: SKU i pode ser produzido na linha l da planta p quando o formato do
    # pedido bate com o formato que a linha sabe fazer.
    C = Set(
        (r.product_id, r.plant, r.production_line)
        for r in eachrow(df_need)
        if haskey(formatos_da_linha, r.production_line) &&
           r.sku_size_shape == formatos_da_linha[r.production_line]
    )

    sets   = (; I, P, T, L_p, C)
    params = (; k, v, ct, eta, r_taxa)
    return (; sets, params, e_max)
end

# Declara as variáveis (todas >= 0, LP contínuo) e as restrições R1–R8.
# Retorna (modelo, vars, cons), com cons guardando as restrições para os duais.
function build_model!(cfg::Config, sets, params, e_max,
                      fabrica_quebrada, limite_caminhoes, fator_demanda)
    (; I, P, T, L_p, C) = sets
    (; k, v, ct, eta, r_taxa) = params

    modelo = Model(() -> Gurobi.Optimizer(GRB_ENV))
    set_silent(modelo)

    @variable(modelo, x[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, e[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, a[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, f[i in I, o in P, d in P, t in T; o != d] >= 0)
    if !cfg.simplificar_docas
        @variable(modelo, g[i in I, p in P, l in L_p[p], t in T] >= 0)
        @variable(modelo, s[i in I, p in P, l in L_p[p], t in T] >= 0)
    end
    @variable(modelo, w[i in I, p in P, l in L_p[p], t in T] >= 0)  # demanda não atendida

    if cfg.simplificar_docas
        vars = (; x, e, a, f, w)
    else
        vars = (; x, e, a, f, g, s, w)
    end
    build_objective!(modelo, cfg, sets, params, vars)

    # R1 – Limite de armazenagem por linha
    cons_R1 = @constraint(modelo, R1[p in P, l in L_p[p], t in T],
        sum(e[i,p,l,t] for i in I) <= e_max[(p,l)]
    )

    # R2 – Balanço de estoque (estoque inicial = 0)
    if cfg.simplificar_docas
        cons_R2 = @constraint(modelo, R2[i in I, p in P, l in L_p[p], t in T],
            e[i,p,l,t] == (t == 1 ? 0.0 : e[i,p,l,t-1]) +
                        x[i,p,l,t] +
                        sum(f[i,o,p,t] for o in P if o != p) / length(L_p[p]) -
                        sum(f[i,p,d,t] for d in P if d != p) / length(L_p[p]) -
                        a[i,p,l,t]
        )
    else
        cons_R2 = @constraint(modelo, R2[i in I, p in P, l in L_p[p], t in T],
            e[i,p,l,t] == (t == 1 ? 0.0 : e[i,p,l,t-1]) +
                        x[i,p,l,t] + g[i,p,l,t] - s[i,p,l,t] - a[i,p,l,t]
        )
    end

    # R3 – Atendimento à demanda (w absorve o que não consegue entregar)
    cons_R3 = @constraint(modelo, R3[i in I, p in P, l in L_p[p], t in T],
        a[i,p,l,t] + w[i,p,l,t] == eta[(i,p,l,t)] * fator_demanda
    )

    # R4 – Capacidade produtiva em horas (desliga planta quebrada)
    cons_R4 = @constraint(modelo, R4[p in P, l in L_p[p], t in T],
        sum(x[i,p,l,t] / (r_taxa[(p,l,t)] * cfg.fator_oee)
        for i in I if (i,p,l) ∈ C && r_taxa[(p,l,t)] > 0) <=
        (p == fabrica_quebrada ? 0.0 : cfg.horas_dia)
    )

    # R5 – Capacidade logística de saída por planta (limite de caminhões)
    cons_R5 = @constraint(modelo, R5[p in P, t in T],
        sum(f[i,p,d,t] / cfg.latas_por_caminhao for i in I, d in P if d != p) <= limite_caminhoes
    )

    # R6 – Doca de saída: s coletando -> f saindo
    # R7 – Doca de entrada: f chegando -> g distribuindo
    if !cfg.simplificar_docas
        cons_R6 = @constraint(modelo, R6[i in I, p in P, t in T],
            sum(s[i,p,l,t] for l in L_p[p]) == sum(f[i,p,d,t] for d in P if d != p)
        )

        cons_R7 = @constraint(modelo, R7[i in I, p in P, t in T],
            sum(g[i,p,l,t] for l in L_p[p]) == sum(f[i,o,p,t] for o in P if o != p)
        )
    else
        cons_R6 = nothing
        cons_R7 = nothing
    end

    # R8 – Trava de formato: impede produção incompatível
    cons_R8 = @constraint(modelo, R8[i in I, p in P, l in L_p[p], t in T; (i,p,l) ∉ C],
        x[i,p,l,t] == 0
    )

    cons = (; R1=cons_R1, R2=cons_R2, R3=cons_R3, R4=cons_R4,
              R5=cons_R5, R6=cons_R6, R7=cons_R7, R8=cons_R8)

    return (modelo, vars, cons)
end

# ==============================================================================
# VALIDAÇÃO ESTRUTURAL
# ==============================================================================

# Registra uma violação de propriedade encontrada por validate_scenario.
struct Violation
    propriedade::Symbol
    indices::NamedTuple
    valor::Float64
end

# Confere propriedades estruturais da solução: balanço de estoque (R2),
# balanço de demanda (R3), não-negatividade e trava de formato. Retorna a lista
# de violações (vazia = tudo ok); não lança exceção.
function validate_scenario(cfg::Config, sets, params, vars; tol=1e-6)
    violations = Violation[]
    (; I, P, T, L_p, C) = sets
    (; eta) = params
    (; x, e, a, w) = vars

    for i in I, p in P, l in L_p[p], t in T
        # R2 – balanço de estoque
        prev_e = t == first(T) ? 0.0 : value(e[i,p,l,t-1])
        if !cfg.simplificar_docas
            g_val = value(vars.g[i,p,l,t])
            s_val = value(vars.s[i,p,l,t])
            residual_r2 = value(e[i,p,l,t]) - (prev_e + value(x[i,p,l,t]) + g_val - s_val - value(a[i,p,l,t]))
        else
            inbound  = sum(value(vars.f[i,o,p,t]) for o in P if o != p) / length(L_p[p])
            outbound = sum(value(vars.f[i,p,d,t]) for d in P if d != p) / length(L_p[p])
            residual_r2 = value(e[i,p,l,t]) - (prev_e + value(x[i,p,l,t]) + inbound - outbound - value(a[i,p,l,t]))
        end
        if abs(residual_r2) > tol
            push!(violations, Violation(:R2_balanco, (i=i, p=p, l=l, t=t), residual_r2))
        end

        # R3 – balanço de demanda
        residual_r3 = value(a[i,p,l,t]) + value(w[i,p,l,t]) - eta[(i,p,l,t)] * cfg.fator_demanda
        if abs(residual_r3) > tol
            push!(violations, Violation(:R3_demanda, (i=i, p=p, l=l, t=t), residual_r3))
        end

        # Não-negatividade
        for (name, val) in [(:x, value(x[i,p,l,t])), (:e, value(e[i,p,l,t])),
                            (:a, value(a[i,p,l,t])), (:w, value(w[i,p,l,t]))]
            if val < -tol
                push!(violations, Violation(:nao_negatividade, (var=name, i=i, p=p, l=l, t=t), val))
            end
        end
        if !cfg.simplificar_docas
            for (name, val) in [(:g, value(vars.g[i,p,l,t])), (:s, value(vars.s[i,p,l,t]))]
                if val < -tol
                    push!(violations, Violation(:nao_negatividade, (var=name, i=i, p=p, l=l, t=t), val))
                end
            end
        end

        # Trava de formato
        if (i,p,l) ∉ C && abs(value(x[i,p,l,t])) > tol
            push!(violations, Violation(:trava_formato, (i=i, p=p, l=l, t=t), value(x[i,p,l,t])))
        end
    end

    # Não-negatividade do frete inter-plantas
    for i in I, o in P, d in P, t in T
        o == d && continue
        f_val = value(vars.f[i,o,d,t])
        if f_val < -tol
            push!(violations, Violation(:nao_negatividade, (var=:f, i=i, o=o, d=d, t=t), f_val))
        end
    end

    return violations
end

# ==============================================================================
# FUNÇÃO PRINCIPAL: monta e resolve um cenário
# ==============================================================================

function resolver_cenario(cenario, fabrica_quebrada, limite_caminhoes, fator_demanda, df_log;
                          cfg::Config = CFG_PADRAO)

    # 1. Leitura dos dados
    df_need, df_rate, df_costs, df_limit = load_scenario_inputs(cfg, cenario)

    # 2. Conjuntos e parâmetros
    (; sets, params, e_max) = build_sets_and_params(cfg, df_need, df_rate, df_costs, df_limit, df_log)

    # 3. Modelo (variáveis + restrições R1–R8)
    (modelo, vars, cons) = build_model!(cfg, sets, params, e_max,
                                        fabrica_quebrada, limite_caminhoes, fator_demanda)

    # 4. Resolve
    optimize!(modelo)
    status = termination_status(modelo)

    # Cenário insolúvel: reporta NaN sem introduzir variáveis inteiras
    status ∉ (MOI.OPTIMAL, MOI.FEASIBLE_POINT) && return (
        cenario          = cenario,
        status           = string(status),
        custo_producao   = NaN, custo_estoque    = NaN,
        custo_logistica  = NaN, custo_penalidade = NaN,
        custo_total      = NaN, demanda_total    = NaN,
        atendido         = NaN, nao_atendido     = NaN,
        taxa_atendimento = NaN, caminhoes        = NaN,
    )

    # 5. Métricas
    metrics = compute_metrics(cfg, modelo, sets, params, vars)

    # 5b. Validação estrutural (loga violações sem abortar o sweep)
    violacoes = validate_scenario(cfg, sets, params, vars)
    if !isempty(violacoes)
        @warn "Validação: cenário ocupacao_$(cenario) — $(length(violacoes)) violação(ões) detectada(s)"
        for viol in violacoes
            @warn "  $(viol.propriedade) em $(viol.indices) | valor = $(viol.valor)"
        end
    end

    # 5c. Extrai e persiste os preços de sombra
    duals = extract_duals(cfg, modelo, cenario, sets, cons, vars)
    if duals !== nothing
        report_duals(cfg, cenario, duals)
    end

    # 6. Export detalhado
    (; I, P, T, L_p) = sets
    (; x, e, a, f, w) = vars
    rows = []
    for p in P, l in L_p[p], i in I, t in T
        push!(rows, (
            cenario    = cenario,
            plant      = p,
            linha      = l,
            produto    = i,
            periodo    = t,
            producao   = value(x[i,p,l,t]),
            estoque    = value(e[i,p,l,t]),
            atendido   = value(a[i,p,l,t]),
            nao_atend  = value(w[i,p,l,t]),
            enviado    = sum(value(f[i,p,d,t]) for d in P if d != p),
            recebido   = sum(value(f[i,o,p,t]) for o in P if o != p),
        ))
    end
    df_det = DataFrame(rows)
    CSV.write(joinpath(cfg.output_dir, "detalhe_ocupacao_$(cenario).csv"), df_det)

    empty!(modelo)
    GC.gc()

    return (
        cenario          = cenario,
        status           = "OPTIMAL",
        custo_producao   = round(metrics.custo_producao, digits=2),
        custo_estoque    = round(metrics.custo_estoque,  digits=2),
        custo_logistica  = round(metrics.custo_logistica,  digits=2),
        custo_penalidade = round(metrics.custo_penalidade,  digits=2),
        custo_total      = round(metrics.custo_total, digits=2),
        demanda_total    = round(metrics.demanda_total, digits=0),
        atendido         = round(metrics.atendido,   digits=0),
        nao_atendido     = round(metrics.nao_atendido,   digits=0),
        taxa_atendimento = round(metrics.taxa_atendimento,       digits=2),
        caminhoes        = round(metrics.caminhoes,  digits=1),
    )

end

# ==============================================================================
# OUTPUT NO TERMINAL
# ==============================================================================

function sep(c="─", n=100) println(c^n) end

function imprimir_painel(fab, lim, fator, oee)
    println()
    sep("═")
    println("  BALL CORPORATION — ANÁLISE DE SENSIBILIDADE")
    println("  Rodado em: $(Dates.format(now(), "dd/mm/yyyy HH:MM"))")
    sep("─")
    println("  CONFIGURAÇÃO DO PAINEL:")
    println("    Fator de demanda  : $(fator)x  $(fator > 1.0 ? "($(round(Int, fator*100))% da demanda original)" : "(normal)")")
    println("    Eficiência (OEE)  : $(round(Int, oee*100))% da capacidade nominal")
    println("    Fábrica quebrada  : $fab")
    println("    Limite caminhões  : $lim caminhões/dia/planta")
    sep("═")
end

function imprimir_tabela(resultados)
    println()
    @printf("  %-9s  %-13s  %-13s  %-13s  %-13s  %-10s  %-8s\n",
        "Cenário", "Custo Prod.", "Custo Estq.", "Custo Log.", "Custo Multa",
        "Atendimento", "Caminhões")
    sep()
    for r in resultados
        if r.status == "OPTIMAL"
            @printf("  ocup_%-4s  %13.2f  %13.2f  %13.2f  %13.2f  %9.2f%%  %9.1f\n",
                r.cenario,
                r.custo_producao, r.custo_estoque,
                r.custo_logistica, r.custo_penalidade,
                r.taxa_atendimento, r.caminhoes)
        else
            @printf("  ocup_%-4s  %-13s  %-13s  %-13s  %-13s  %-10s  %-9s  [%s]\n",
                r.cenario, "---","---","---","---","---","---", r.status)
        end
    end
    sep()

    # Resumo ao final
    opts = filter(r -> r.status == "OPTIMAL", resultados)
    if !isempty(opts)
        println()
        println("  RESUMO:")
        @printf("    Cenários resolvidos    : %d / %d\n", length(opts), length(resultados))
        @printf("    Custo total mínimo     : R\$ %.2f  (ocupacao_%s)\n",
            minimum(r.custo_total for r in opts),
            resultados[argmin([isnan(r.custo_total) ? Inf : r.custo_total for r in resultados])].cenario)
        @printf("    Custo total máximo     : R\$ %.2f  (ocupacao_%s)\n",
            maximum(r.custo_total for r in opts),
            resultados[argmax([isnan(r.custo_total) ? -Inf : r.custo_total for r in resultados])].cenario)
        @printf("    Taxa de atendimento    : %.2f%% (min) — %.2f%% (max)\n",
            minimum(r.taxa_atendimento for r in opts),
            maximum(r.taxa_atendimento for r in opts))
        demanda_perdida = sum(r.nao_atendido for r in opts)
        demanda_perdida > 0 &&
            @printf("    ⚠ Demanda não atendida : %.0f latas no total (veja Custo Multa)\n",
                demanda_perdida)
    end
    println()
end

function imprimir_evolucao(resultados)
    opts = filter(r -> r.status == "OPTIMAL", resultados)
    isempty(opts) && return

    println("\n  EVOLUÇÃO ENTRE CENÁRIOS (delta em relação ao anterior):")
    sep()
    @printf("  %-9s  %13s  %13s  %13s  %13s  %10s  %9s\n",
        "Cenário", "Δ CustoProd", "Δ CustoEstq", "Δ CustoLog", "Δ CustoMulta", "Δ Atend%", "Δ Caminhões")
    sep()

    prev = nothing
    for r in opts
        if prev === nothing
            @printf("  ocup_%-4s  %13.2f  %13.2f  %13.2f  %13.2f  %9.2f%%  %9.1f\n",
                r.cenario, r.custo_producao, r.custo_estoque,
                r.custo_logistica, r.custo_penalidade,
                r.taxa_atendimento, r.caminhoes)
        else
            @printf("  ocup_%-4s  %+13.2f  %+13.2f  %+13.2f  %+13.2f  %+9.2f%%  %+9.1f\n",
                r.cenario,
                r.custo_producao  - prev.custo_producao,
                r.custo_estoque   - prev.custo_estoque,
                r.custo_logistica - prev.custo_logistica,
                r.custo_penalidade - prev.custo_penalidade,
                r.taxa_atendimento - prev.taxa_atendimento,
                r.caminhoes        - prev.caminhoes)
        end
        prev = r
    end
    sep()
end

# ==============================================================================
# EXECUÇÃO
# ==============================================================================

const CFG = CFG_PADRAO
resolve_paths(CFG)

# O CSV de custos logísticos é compartilhado e fica na raiz de input_dir.
df_log = CSV.read(joinpath(CFG.input_dir, "input_logistic_costs_artificial.csv"), DataFrame)

imprimir_painel(fabrica_quebrada, limite_caminhoes, fator_demanda, fator_oee)

println("\n  Resolvendo $(length(CENARIOS)) cenários...\n")
resultados = []
for (idx, cenario) in enumerate(CENARIOS)
    r = resolver_cenario(cenario, fabrica_quebrada, limite_caminhoes, fator_demanda, df_log;
                         cfg = CFG)
    push!(resultados, r)
    progresso(idx, length(CENARIOS), "ocupacao_$cenario")
end

imprimir_tabela(resultados)
imprimir_evolucao(resultados)

# Exporta o CSV consolidado
df_saida = DataFrame(resultados)
df_saida.fabrica_quebrada .= fabrica_quebrada
df_saida.limite_caminhoes .= limite_caminhoes
df_saida.fator_demanda    .= fator_demanda

timestamp    = Dates.format(now(), "yyyymmdd_HHMM")
nome_arquivo = "resultados_$(fabrica_quebrada)_cam$(limite_caminhoes)_fator$(fator_demanda)_$(timestamp).csv"
CSV.write(joinpath(CFG.output_dir, nome_arquivo), df_saida)
println("  Resultados salvos em: $(joinpath(CFG.output_dir, nome_arquivo))\n")
