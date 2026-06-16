using JuMP
using Gurobi
using CSV
using DataFrames

# ==============================================================================
# PASSO 1: Leitura dos Dados
# ==============================================================================

custos        = CSV.read("custos.csv", DataFrame)
demanda_prazos = CSV.read("demanda_prazos.csv", DataFrame)
producao     = CSV.read("produção.csv", DataFrame)
custo_prod_df = CSV.read("custo_producao.csv", DataFrame)
custo_prod = Dict((row[:product_id], row[:production_line]) => row[:custo_producao_por_lata]
                  for row in eachrow(custo_prod_df))

# ==============================================================================
# PASSO 2: Limpeza da Coluna prod_need (vírgula → ponto, string → float)
# ==============================================================================

demanda_prazos[!, :prod_need] = parse.(Float64, replace.(string.(demanda_prazos[!, :prod_need]), "," => "."))

# ==============================================================================
# PASSO 3: Mapeamento do Horizonte de Tempo (datas → t01, t02, ..., t15)
# ==============================================================================

datas_unicas = sort(unique(demanda_prazos[!, :deadline]))
mapeamento_T = Dict(d => "t$(lpad(i, 2, '0'))" for (i, d) in enumerate(datas_unicas))

# Aplicar mapeamento na tabela de demanda
demanda_prazos[!, :periodo_t] = [mapeamento_T[d] for d in demanda_prazos[!, :deadline]]

# ==============================================================================
# PASSO 4: Definição dos Conjuntos
# ==============================================================================

I = unique(demanda_prazos[!, :product_id])        # SKUs
L = unique(demanda_prazos[!, :production_line])    # Linhas de produção
P = unique(demanda_prazos[!, :plant])              # Plantas / Destinos
T = sort(unique(demanda_prazos[!, :periodo_t]))    # Períodos t01..t15

println("Conjuntos carregados:")
println("  |I| = $(length(I)) SKUs")
println("  |L| = $(length(L)) Linhas")
println("  |P| = $(length(P)) Plantas")
println("  |T| = $(length(T)) Períodos")

# ==============================================================================
# PASSO 5: Mapeamento Hierárquico linha → planta  (ϕ(l) = p)
# ==============================================================================

phi = Dict(row[:production_line] => row[:plant] for row in eachrow(demanda_prazos))

# ==============================================================================
# PASSO 6: Parâmetros
# ==============================================================================

# --- Custo logístico ct[(origem, destino)] ---
ct = Dict{Tuple{String,String}, Float64}()
for row in eachrow(custos)
    o = row[:origem]
    d = row[:destino]
    ct[(o, d)] = (o == d) ? 0.0 : round(row[:custo_combustivel] + row[:custo_pedagio] + row[:custo_mao_de_obra], digits=2)
end

# --- Demanda n[(i, j, t)] ---
# j = plant (destino da produção), t = periodo mapeado
n = Dict{Tuple{String,String,String}, Float64}()
for row in eachrow(demanda_prazos)
    key = (row[:product_id], row[:plant], row[:periodo_t])
    n[key] = get(n, key, 0.0) + row[:prod_need]
end

# --- Taxa de produção r[(l, t)] ---
# Filtro de consistência: só datas dentro do horizonte
datas_validas = Set(keys(mapeamento_T))
producao_valida = filter(row -> row[:ref_date] in datas_validas, producao)

r = Dict{Tuple{String,String}, Float64}()
for row in eachrow(producao_valida)
    t = mapeamento_T[row[:ref_date]]
    r[(row[:production_line], t)] = Float64(row[:rate])
end

# Valor padrão para combinações ausentes (evita KeyError na R3)
r_safe(l, t) = get(r, (l, t), 0.0)

# ==============================================================================
# PASSO 7: Instanciação do Modelo
# ==============================================================================

modelo = Model(Gurobi.Optimizer)

# ==============================================================================
# PASSO 8: Variável de Decisão  x[i, l, j, t] >= 0
# ==============================================================================

@variable(modelo, x[I, L, P, T] >= 0)

# ==============================================================================
# PASSO 9: Função Objetivo — Minimizar custo logístico total
#
#   # min Z = Σ_{i,l,j,t} ( k[i,l] + ct[ϕ(l),j] / 200_000 ) × x[i,l,j,t]
# ==============================================================================

@objective(modelo, Min,
    sum(
        (get(custo_prod, (i, l), 0.0) + get(ct, (phi[l], j), 0.0) / 200_000) * x[i, l, j, t]
        for i in I, l in L, j in P, t in T
    )
)

# ==============================================================================
# PASSO 10: Restrições
# ==============================================================================

# R1 — Capacidade de expedição: máximo 80 caminhões por planta por dia
@constraint(modelo, R1[p in P, t in T],
    sum(
        x[i, l, j, t] / 200_000
        for i in I, l in L, j in P
        if phi[l] == p
    ) <= 80
)

# R2 — Atendimento à demanda: produção total >= necessidade
@constraint(modelo, R2[i in I, j in P, t in T],
    sum(x[i, l, j, t] for l in L) >= get(n, (i, j, t), 0.0)
)

# R3 — Capacidade de manufatura: horas usadas <= 24h por linha por dia
@constraint(modelo, R3[l in L, t in T],
    sum(
        x[i, l, j, t] / r_safe(l, t)
        for i in I, j in P
        if r_safe(l, t) > 0
    ) <= 24
)

# ==============================================================================
# PASSO 11: Otimização
# ==============================================================================

optimize!(modelo)

# ==============================================================================
# PASSO 12: Resultados
# ==============================================================================

status = termination_status(modelo)

if status == MOI.OPTIMAL
    println("\n✓ Solução ótima encontrada!")
    println("  Custo Total Mínimo: R\$ $(round(objective_value(modelo), digits=2))")

    # Resumo por planta de origem
    println("\nResumo de caminhões despachados por planta:")
    for p in P
        total_caminhoes = sum(
            value(x[i, l, j, t]) / 200_000
            for i in I, l in L, j in P, t in T
            if phi[l] == p
        )
        println("  $p: $(round(total_caminhoes, digits=2)) caminhões no total")
    end

    # Resumo por período
    println("\nCusto logístico por período:")
    for t in T
        custo_t = sum(
            (get(ct, (phi[l], j), 0.0) / 200_000) * value(x[i, l, j, t])
            for i in I, l in L, j in P
        )
        println("  $t: R\$ $(round(custo_t, digits=2))")
    end

else
    println("\n✗ Solução ótima não encontrada. Status: $status")
end