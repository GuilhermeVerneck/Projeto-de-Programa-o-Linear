using JuMP
using Gurobi
using CSV
using DataFrames

# ==============================================================================
# 1. FUNÇÃO DE LIMPEZA DE DADOS (O problema da vírgula)
# ==============================================================================
# Converte as strings com vírgula do padrão brasileiro para Float no Julia
function parse_br_float(val)
    if ismissing(val) || val == "" 
        return 0.0 
    end
    return parse(Float64, replace(String(val), "," => "."))
end

# ==============================================================================
# 2. CONFIGURAÇÃO DOS CENÁRIOS E VARIÁVEIS GLOBAIS
# ==============================================================================
caminho_base = "C:\\Unifesp\\Programação Linear\\Trabalho Programação Linear\\Dados\\"

# O custo logístico é global (físico), lemos fora do laço!
df_log = CSV.read(caminho_base * "input_logistic_costs_artificial.csv", DataFrame)


# Iterando de 50% a 150% com passo de 5%
cenarios = ["50", "55", "60", "65", "70", "75", "80", "85", "90", 
            "95", "100", "105", "110", "115", "120", "125", "130", 
            "135", "140", "145", "150"]

resultados_custo = []

for cenario in cenarios
    println("\n==================================================")
    println("Montando e Resolvendo Cenário: ", cenario)
    
    # --------------------------------------------------------------------------
    # 3. LEITURA DOS DADOS DO CENÁRIO ATUAL
    # --------------------------------------------------------------------------
    # Ajuste o caminho conforme as pastas do seu computador
    caminho_pasta = "C:\\Unifesp\\Programação Linear\\Trabalho Programação Linear\\Dados\\ocupacao_" * cenario * "\\"
    
    df_need  = CSV.read(caminho_pasta * "input_production_need_artificial.csv", DataFrame)
    df_rate  = CSV.read(caminho_pasta * "input_production_rate_artificial.csv", DataFrame)
    df_costs = CSV.read(caminho_pasta * "input_sku_costs_artificial.csv", DataFrame) # (Se houver)
    df_limit = CSV.read(caminho_pasta * "input_line_storage_limit_artificial.csv", DataFrame)

    # Tratamento da vírgula na demanda
    df_need.prod_need = parse_br_float.(df_need.prod_need)

    # --------------------------------------------------------------------------
    # 4. EXTRAÇÃO DOS CONJUNTOS (Substitua pela sua lógica de extração)
    # --------------------------------------------------------------------------
    I = unique(df_need.product_id)         # SKUs
    P = unique(df_rate.plant)              # Plantas
    T = 1:15                               # Horizonte de 15 dias
    
    # Dicionário mapeando as linhas l contidas em cada planta p (L_p)
    # Exemplo: L_p["Jacarei"] = ["JAC_L1", "JAC_L2", "JAC_L3"]
    L_p = Dict(p => unique(df_rate[df_rate.plant .== p, :production_line]) for p in P)

    # OBS: Crie aqui os dicionários de parâmetros (eta, r, k, v, ct, e_max) 
    # a partir dos DataFrames filtrados para usar nas equações abaixo.
    

# --------------------------------------------------------------------------
    # 4.B CRIANDO OS DICIONÁRIOS DE PARÂMETROS
    # --------------------------------------------------------------------------
    
    # 1. Custos de Produção (k) e Estoque (v)
    k = Dict()
    v = Dict()
    for linha in eachrow(df_costs)
        k[(linha.product_id, linha.plant, linha.production_line)] = linha.production_cost
        v[(linha.product_id, linha.plant, linha.production_line)] = linha.inventory_cost
    end

    # 2. Custo Logístico de Frete (ct)
    ct = Dict()
    for linha in eachrow(df_log)
        ct[(linha.origem, linha.destino)] = linha.custo_total_frete
    end
    
    # 3. Limite de Armazém (e_max)
    e_max = Dict()
    for linha in eachrow(df_limit)
        e_max[(linha.plant, linha.production_line)] = linha.storage_limit
    end

    # 4. Demanda do Cliente (eta)
    eta = Dict()
    # Primeiro preenchemos com 0.0 usando laços aninhados seguros
    for i in I
        for p in P
            for l in L_p[p]
                for t in T
                    eta[(i, p, l, t)] = 0.0
                end
            end
        end
    end
    
    # AGORA SIM: Lemos o CSV e colocamos os pedidos reais!
    for linha in eachrow(df_need)
        dia_str = string(linha.deadline)[9:10]
        t = parse(Int, dia_str) 
        eta[(linha.product_id, linha.plant, linha.production_line, t)] += linha.prod_need
    end

    # 5. Taxas de Produção da Máquina (r)
    r = Dict()
    # Primeiro preenchemos com 0.0 usando laços aninhados seguros
    for p in P
        for l in L_p[p]
            for t in T
                r[(p, l, t)] = 0.0
            end
        end
    end
    
    # AGORA SIM: Lemos o CSV e colocamos a velocidade real das máquinas!
    for linha in eachrow(df_rate)
        dia_str = string(linha.ref_date)[9:10]
        t = parse(Int, dia_str)
        r[(linha.plant, linha.production_line, t)] = linha.rate
    end

    # --------------------------------------------------------------------------
    # 5. INICIALIZAÇÃO DO MODELO GUROBI
    # --------------------------------------------------------------------------
    modelo = Model(Gurobi.Optimizer)
    # set_silent(modelo) # Descomente se não quiser ver o log do Gurobi na tela
    
    # --------------------------------------------------------------------------
    # 6. VARIÁVEIS DE DECISÃO
    # --------------------------------------------------------------------------
    @variable(modelo, x[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, e[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, a[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, f[i in I, o in P, d in P, t in T; o != d] >= 0)
    @variable(modelo, g[i in I, p in P, l in L_p[p], t in T] >= 0)
    @variable(modelo, s[i in I, p in P, l in L_p[p], t in T] >= 0)
 

    # Regra Crítica: Produção = 0 se o formato da linha não for compatível com o SKU
    # (Adicione um laço if verificando o conjunto C e force fix_value(x[i,p,l,t], 0))

    # --------------------------------------------------------------------------
    # 7. FUNÇÃO OBJETIVO
    # --------------------------------------------------------------------------
    @objective(modelo, Min,
        sum(k[i,p,l] * x[i,p,l,t] for p in P, l in L_p[p], i in I, t in T) +
        sum(v[i,p,l] * e[i,p,l,t] for p in P, l in L_p[p], i in I, t in T) +
        sum(ct[o,d] * (f[i,o,d,t] / 200000) for i in I, o in P, d in P, t in T if o != d) 
    )
    # --------------------------------------------------------------------------
    # 8. RESTRIÇÕES DO SISTEMA (Baseado na Formulação Compacta)
    # --------------------------------------------------------------------------
    # R1 - Limite de Armazenagem da Linha
    @constraint(modelo, R1[p in P, l in L_p[p], t in T],
        sum(e[i,p,l,t] for i in I) <= e_max[p,l]
    )

    #R2 - Balanço de Estoque (com condição inicial do armazém vazio)
    @constraint(modelo, R2[i in I, p in P, l in L_p[p], t in T],
        e[i,p,l,t] == (t == 1 ? 0.0 : e[i,p,l,t-1]) + x[i,p,l,t] + g[i,p,l,t] - s[i,p,l,t] - a[i,p,l,t]
    )

    # R3 - Atendimento à Demanda (com folga de capacidade)
    @constraint(modelo, R3[i in I, p in P, l in L_p[p], t in T],
        a[i,p,l,t] >= eta[i,p,l,t] # AQUI MUDOU PARA ==
    )

    # R4 - Capacidade Produtiva (24 horas)
    @constraint(modelo, R4[p in P, l in L_p[p], t in T],
        # Só soma se a taxa de produção (r) existir e for maior que zero para blindar divisão por zero
        sum(x[i,p,l,t] / r[p,l,t] for i in I if r[p,l,t] > 0) <= 24
    )

    # R5 - Capacidade Logística de Expedição (80 caminhões)
    @constraint(modelo, R5[p in P, t in T],
        sum(f[i,p,d,t] / 200000 for i in I, d in P if d != p) <= 80
    )

    # R7 - Transbordo na Doca de Entrada
    @constraint(modelo, R7[i in I, p in P, t in T],
        sum(g[i,p,l,t] for l in L_p[p]) == sum(f[i,o,p,t] for o in P if o != p)
    )

    # R8 - Capabilidade (Impede produção incompatível com o formato da planta)
    # A função !haskey(k, (i,p,l)) significa: "Se a chave (i,p,l) NÃO existe no dicionário k"
    @constraint(modelo, R8[i in I, p in P, l in L_p[p], t in T; !haskey(k, (i,p,l))],
        x[i,p,l,t] == 0
    )

    # --------------------------------------------------------------------------
    # 9. SOLUÇÃO E OUTPUT
    # --------------------------------------------------------------------------
 # --------------------------------------------------------------------------
    # 9. SOLUÇÃO E OUTPUT (O Relatório da Diretoria)
    # --------------------------------------------------------------------------
    optimize!(modelo)
    status = termination_status(modelo)
    
    if status == MOI.OPTIMAL
        custo_final = objective_value(modelo)
        println("✓ Solução ótima encontrada para o cenário de ", cenario, "%")
        println("  Custo Total: R\$ $(round(custo_final, digits=2))")
        println("  ✓ ATENDIMENTO: 100% dos pedidos entregues no prazo!")
        
        # Pode manter aqui o seu laço de impressão dos caminhões f...
        
    elseif status == MOI.INFEASIBLE
        println("\n✗ ALERTA FATAL: INFEASIBLE no cenário de ", cenario, "%")
        println("  A matemática provou que é fisicamente impossível atender essa demanda.")
        println("  Motivo: A restrição R4 (24 horas) travou a produção, não gerou estoque suficiente (R2), e falhou em cumprir a exigência cega da R3.")
    else
        println("Status inexperado: ", status)
    end
end