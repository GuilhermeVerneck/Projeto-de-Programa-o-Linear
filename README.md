# Linear Programming Project — Ball Corporation Supply Network

> Macroscopic production and logistics planning for an aluminum-can manufacturing
> network, modeled as a continuous Linear Program (LP) in Julia/JuMP and solved
> with Gurobi. Final project for the Linear Optimization course (UNIFESP).

*English version below. Versão em português logo em seguida ([ir para o português](#projeto-de-programação-linear--rede-de-suprimentos-ball-corporation)).*

---

## English

### Overview

This project models the industrial supply network of **Ball Corporation** (an aluminum
beverage-can maker) as a cost-minimization Linear Program over a **15-day** planning
horizon. The network has:

- **10 plants** — Jacareí, Extrema, Três Rios, Alagoinhas, Frutal, Pouso Alegre, Gama, Viamão, Itupeva, Cabo de Santo Agostinho
- **30 production lines** — 3 per plant
- **30 SKUs** — beverage brands (Coca-Cola, Pepsi, Heineken, Skol, Guaraná Antarctica, …)
- **3 can formats** — 9.1 oz Sleek, 12 oz Standard, 16 oz Tall (each plant runs one format)

The model decides, for every SKU/line/day, how much to **produce**, **store**, **ship
between plants**, and **deliver**, minimizing total operating cost while respecting
machine-hour, storage, and truck-fleet limits. Demand that physically cannot be met is
absorbed by a penalized *lost-sales* variable (Big-M), so the model stays feasible even
under extreme stress and lets us compare scenarios.

The complete mathematical write-up (sets, parameters, variables, objective, constraints,
and the Julia implementation) is in **[`relatorio/otimizacao.pdf`](relatorio/otimizacao.pdf)**.

### The optimization model

Objective — minimize the sum of four cost components:

```
min Z = production cost + inventory cost + logistics (freight) cost + Big-M lost-sales penalty
```

**Decision variables** (all continuous, ≥ 0):

| Variable | Meaning |
|----------|---------|
| `x[i,p,l,t]` | production of SKU *i* on line *l* of plant *p* on day *t* |
| `e[i,p,l,t]` | end-of-day inventory |
| `a[i,p,l,t]` | local demand fulfillment (the only variable that "touches" the customer) |
| `f[i,o,d,t]` | inter-plant transfer of SKU *i* from plant *o* to plant *d* |
| `g[i,p,l,t]` | inbound-dock redistribution to a line's warehouse |
| `s[i,p,l,t]` | outbound-dock collection from a line's warehouse |
| `w[i,p,l,t]` | unmet demand / lost sales (Big-M penalized slack) |

**Constraints:**

| # | Description |
|---|-------------|
| R1 | Storage capacity per line (shared across SKUs) |
| R2 | Inventory balance / mass conservation (couples all 15 days) |
| R3 | Demand fulfillment: `a + w = demand` |
| R4 | Productive capacity in machine-hours (24 h/day; 0 h if the plant is "broken") |
| R5 | Outbound logistics capacity (≤ 80 trucks/day/plant; 1 truck = 200,000 cans) |
| R6 / R7 | Mass conservation at the transshipment docks |
| R8 | Format capability — a line only produces SKUs matching its format |
| R9 | Non-negativity |

Roughly **126,000 variables** in total.

### Repository structure

```
.
├── Instancias/                   # input data: 21 occupancy scenarios + shared freight matrix
├── modelo/                       # source code
│   ├── modelagem.jl              # ★ final model (JuMP + Gurobi, scenario sweep)
│   ├── modelagem_restrita.jl     # restricted variant
│   ├── modelagem_errata.jl       # earlier/erratum variant
│   └── exploracao_dados.ipynb    # data-exploration notebook (pandas)
├── relatorio/                    # documentation
│   ├── otimizacao.pdf / .tex     # full model report (recommended reading)
│   ├── otimizacao_restrita.*     # report for the restricted variant
│   └── apresentacao.pdf          # slide deck
├── resultados/                   # baseline optimization outputs (see below)
├── .gitignore
└── README.md
```

### Data / instances

The input instances **are included** in the `Instancias/` folder (configurable via the
`Config` struct in `modelo/modelagem.jl`), so the project is reproducible out of the box.

Layout — one subfolder per occupancy scenario (`ocupacao_50` … `ocupacao_150`):

```
Instancias/
├── input_logistic_costs_artificial.csv        # shared freight-cost matrix (origin→destination)
├── ocupacao_50/
│   ├── input_production_need_artificial.csv    # demand η (SKU, line, deadline, prod_need)
│   ├── input_production_rate_artificial.csv    # line rate (cans/hour) + format (sku_size_shape)
│   ├── input_sku_costs_artificial.csv          # production cost k and inventory cost v
│   └── input_line_storage_limit_artificial.csv # storage limit per line
├── ocupacao_55/ …
└── ocupacao_150/
```

Notes on the data: monetary values use the **Brazilian decimal comma** (handled by
`parse_br_float`); deadlines are civil timestamps mapped to days `t ∈ {1,…,15}`; about
**10% of orders arrive with a format incompatible** with their line, which forces the
model to solve them via inter-plant transfers. The `modelo/exploracao_dados.ipynb`
notebook documents and cleans these raw files.

### Requirements & how to run

- **Julia** ≥ 1.9 with packages `JuMP`, `Gurobi`, `CSV`, `DataFrames`, `Printf`, `Dates`
- A working **Gurobi** license (free academic licenses are available)

```julia
julia> import Pkg; Pkg.add(["JuMP", "Gurobi", "CSV", "DataFrames"])
```

Then, from the `modelo/` folder, run (the `Instancias/` folder ships with the repo):

```bash
julia modelagem.jl
```

The script solves all 21 occupancy scenarios (`ocupacao_50` … `ocupacao_150`) for the
configuration set in the **control panel** at the top of the file and writes the CSV
outputs to `../saidas` (a consolidated summary plus per-scenario detail and dual files).

### Results summary

The `resultados/` folder holds the **baseline sweep**: no broken plant, 80 trucks/day/plant,
demand factor 1.0, across all 21 occupancy levels. Representative rows:

| Scenario | Total demand (cans) | Fulfilled | Fulfillment rate | Production cost (R$) |
|:--------:|--------------------:|----------:|:----------------:|---------------------:|
| ocupacao_50  |  8.64 M | 8.64 M  | **100.00 %** |  72.5 M |
| ocupacao_75  | 12.91 M | 12.91 M | **100.00 %** | 111.2 M |
| ocupacao_95  | 16.43 M | 16.43 M | **100.00 %** | 142.3 M |
| ocupacao_100 | 17.32 M | 17.30 M | 99.87 %      | 151.3 M |
| ocupacao_110 | 19.10 M | 17.35 M | 90.87 %      | 151.6 M |
| ocupacao_125 | 21.68 M | 17.34 M | 79.98 %      | 148.2 M |
| ocupacao_150 | 25.91 M | 17.31 M | 66.80 %      | 147.7 M |

**Key findings:**

- **The network fully satisfies demand up to ~95% occupancy.** From `ocupacao_50` to
  `ocupacao_95`, fulfillment is 100% and the lost-sales penalty is zero.
- **Saturation begins at ~100% occupancy.** The first lost sales appear at `ocupacao_100`
  (0.13% unmet), then fulfillment degrades steadily to **66.8% at `ocupacao_150`**.
- **There is a hard physical ceiling of ≈ 17.3 million cans** deliverable over the 15-day
  horizon. Beyond it, extra demand becomes lost sales rather than extra output — which is
  why **production cost plateaus around R$ 145–151 M** while demand keeps climbing.
- **The binding bottleneck is machine capacity (R4)**, not storage: the storage shadow
  prices (`gamma_armazenagem`) are essentially zero throughout, while the demand shadow
  price (`pi_demanda`) hits the Big-M value exactly where lost sales occur.
- **Logistics is cheap and secondary** (≈ R$ 0.3–0.7 M vs. > R$ 140 M of production):
  the network produces mostly locally, using inter-plant transfers mainly to cover the
  ~10% of format-incompatible orders.

> Because unmet demand is penalized with Big-M (R$ 1,000,000/can), the `custo_total` column
> explodes once lost sales appear. Compare stressed scenarios by **fulfillment rate** and
> the physical cost components, not by total cost.

Output files in `resultados/`:

- `resultados_Nenhuma_cam80_fator1.0_*.csv` — consolidated summary (one row per scenario)
- `detalhe_ocupacao_<N>.csv` — per SKU/plant/line/day solution
- `duals_capacidade_ocupacao_<N>.csv` — machine-hour (μ) and storage (γ) shadow prices
- `duals_demanda_ocupacao_<N>.csv` — demand (π) shadow prices and saturation flags

### Sensitivity analysis

The control panel in `modelo/modelagem.jl` exposes three perturbation axes for what-if
analysis:

- `fabrica_quebrada` — shut a plant down (0 machine-hours) to find critical plants;
- `limite_caminhoes` — tighten the truck fleet (e.g. 80 → 40 → 10) to stress logistics;
- `fator_demanda` — scale all demand (1.0 → 2.0 → 3.0) to simulate demand shocks.

See section 10 of `relatorio/otimizacao.pdf` for a suggested experiment plan.

---

## Projeto de Programação Linear — Rede de Suprimentos Ball Corporation

> Planejamento macroscópico de produção e logística de uma rede de fábricas de latas de
> alumínio, modelado como um Programa Linear (PL) contínuo em Julia/JuMP e resolvido com
> Gurobi. Projeto final da disciplina de Otimização Linear (UNIFESP).

### Visão geral

Este projeto modela a malha industrial da **Ball Corporation** (fabricante de latas de
alumínio para bebidas) como um Programa Linear de minimização de custos sobre um horizonte
de **15 dias**. A rede possui:

- **10 plantas** — Jacareí, Extrema, Três Rios, Alagoinhas, Frutal, Pouso Alegre, Gama, Viamão, Itupeva, Cabo de Santo Agostinho
- **30 linhas de produção** — 3 por planta
- **30 SKUs** — marcas de bebidas (Coca-Cola, Pepsi, Heineken, Skol, Guaraná Antarctica, …)
- **3 formatos de lata** — 9.1 Oz Sleek, 12 Oz Standard, 16 Oz Tall (cada planta opera um formato)

O modelo decide, para cada SKU/linha/dia, quanto **produzir**, **estocar**, **transferir
entre plantas** e **entregar**, minimizando o custo total de operação e respeitando os
limites de horas-máquina, armazenagem e frota de caminhões. A demanda que fisicamente não
pode ser atendida é absorvida por uma variável de **venda perdida** penalizada (Big-M),
de modo que o modelo permanece viável mesmo sob estresse extremo e permite comparar
cenários.

A formulação matemática completa (conjuntos, parâmetros, variáveis, função objetivo,
restrições e a implementação em Julia) está em
**[`relatorio/otimizacao.pdf`](relatorio/otimizacao.pdf)**.

### O modelo de otimização

Função objetivo — minimizar a soma de quatro componentes de custo:

```
min Z = custo de produção + custo de estoque + custo logístico (frete) + penalidade Big-M por venda perdida
```

**Variáveis de decisão** (todas contínuas, ≥ 0):

| Variável | Significado |
|----------|-------------|
| `x[i,p,l,t]` | produção do SKU *i* na linha *l* da planta *p* no dia *t* |
| `e[i,p,l,t]` | estoque ao final do dia |
| `a[i,p,l,t]` | atendimento local da demanda (única variável que "toca" o cliente) |
| `f[i,o,d,t]` | transferência do SKU *i* da planta *o* para a planta *d* |
| `g[i,p,l,t]` | redistribuição da doca de entrada para o armazém da linha |
| `s[i,p,l,t]` | coleta do armazém da linha para a doca de saída |
| `w[i,p,l,t]` | demanda não atendida / venda perdida (folga penalizada por Big-M) |

**Restrições:**

| # | Descrição |
|---|-----------|
| R1 | Capacidade de armazenagem por linha (compartilhada entre SKUs) |
| R2 | Balanço de estoque / conservação de massa (acopla os 15 dias) |
| R3 | Atendimento à demanda: `a + w = demanda` |
| R4 | Capacidade produtiva em horas-máquina (24 h/dia; 0 h se a planta estiver "quebrada") |
| R5 | Capacidade logística de saída (≤ 80 caminhões/dia/planta; 1 caminhão = 200.000 latas) |
| R6 / R7 | Conservação de massa nas docas de transbordo |
| R8 | Capabilidade de formato — a linha só produz SKUs compatíveis com seu formato |
| R9 | Não-negatividade |

São cerca de **126.000 variáveis** no total.

### Estrutura do repositório

```
.
├── Instancias/                   # dados de entrada: 21 cenários de ocupação + matriz de frete
├── modelo/                       # código-fonte
│   ├── modelagem.jl              # ★ modelo final (JuMP + Gurobi, varre os cenários)
│   ├── modelagem_restrita.jl     # variante restrita
│   ├── modelagem_errata.jl       # variante anterior / errata
│   └── exploracao_dados.ipynb    # notebook de exploração dos dados (pandas)
├── relatorio/                    # documentação
│   ├── otimizacao.pdf / .tex     # relatório completo do modelo (leitura recomendada)
│   ├── otimizacao_restrita.*     # relatório da variante restrita
│   └── apresentacao.pdf          # slides
├── resultados/                   # saídas da otimização (cenário base; ver abaixo)
├── .gitignore
└── README.md
```

### Dados / instâncias

As instâncias de entrada **estão incluídas** na pasta `Instancias/` (configurável no struct
`Config` em `modelo/modelagem.jl`), de modo que o projeto é reprodutível diretamente.

Layout — uma subpasta por cenário de ocupação (`ocupacao_50` … `ocupacao_150`):

```
Instancias/
├── input_logistic_costs_artificial.csv        # matriz de frete compartilhada (origem→destino)
├── ocupacao_50/
│   ├── input_production_need_artificial.csv    # demanda η (SKU, linha, prazo, prod_need)
│   ├── input_production_rate_artificial.csv    # taxa da linha (latas/hora) + formato (sku_size_shape)
│   ├── input_sku_costs_artificial.csv          # custo de produção k e de estoque v
│   └── input_line_storage_limit_artificial.csv # limite de armazenagem por linha
├── ocupacao_55/ …
└── ocupacao_150/
```

Observações sobre os dados: os valores monetários usam a **vírgula decimal brasileira**
(tratada por `parse_br_float`); os prazos são carimbos de data/hora mapeados para dias
`t ∈ {1,…,15}`; cerca de **10% dos pedidos chegam com formato incompatível** com sua linha,
o que obriga o modelo a resolvê-los via transferências entre plantas. O notebook
`modelo/exploracao_dados.ipynb` documenta e limpa esses arquivos brutos.

### Requisitos e como executar

- **Julia** ≥ 1.9 com os pacotes `JuMP`, `Gurobi`, `CSV`, `DataFrames`, `Printf`, `Dates`
- Uma licença **Gurobi** válida (há licenças acadêmicas gratuitas)

```julia
julia> import Pkg; Pkg.add(["JuMP", "Gurobi", "CSV", "DataFrames"])
```

Depois, a partir da pasta `modelo/`, rode (a pasta `Instancias/` já vem no repositório):

```bash
julia modelagem.jl
```

O script resolve os 21 cenários de ocupação (`ocupacao_50` … `ocupacao_150`) para a
configuração definida no **painel de controle** no topo do arquivo e grava as saídas em
CSV em `../saidas` (um resumo consolidado, além dos arquivos de detalhe e de variáveis
duais por cenário).

### Resumo dos resultados

A pasta `resultados/` contém a **varredura do cenário base**: nenhuma planta quebrada,
80 caminhões/dia/planta, fator de demanda 1.0, para todos os 21 níveis de ocupação.
Linhas representativas:

| Cenário | Demanda total (latas) | Atendido | Taxa de atendimento | Custo de produção (R$) |
|:-------:|----------------------:|---------:|:-------------------:|-----------------------:|
| ocupacao_50  |  8,64 M | 8,64 M  | **100,00 %** |  72,5 M |
| ocupacao_75  | 12,91 M | 12,91 M | **100,00 %** | 111,2 M |
| ocupacao_95  | 16,43 M | 16,43 M | **100,00 %** | 142,3 M |
| ocupacao_100 | 17,32 M | 17,30 M | 99,87 %      | 151,3 M |
| ocupacao_110 | 19,10 M | 17,35 M | 90,87 %      | 151,6 M |
| ocupacao_125 | 21,68 M | 17,34 M | 79,98 %      | 148,2 M |
| ocupacao_150 | 25,91 M | 17,31 M | 66,80 %      | 147,7 M |

**Principais conclusões:**

- **A rede atende 100% da demanda até ~95% de ocupação.** De `ocupacao_50` a
  `ocupacao_95`, o atendimento é total e a penalidade por venda perdida é zero.
- **A saturação começa em ~100% de ocupação.** As primeiras vendas perdidas aparecem em
  `ocupacao_100` (0,13% não atendido) e o atendimento cai de forma contínua até
  **66,8% em `ocupacao_150`**.
- **Existe um teto físico de ≈ 17,3 milhões de latas** entregáveis no horizonte de 15
  dias. Acima dele, a demanda extra vira venda perdida em vez de produção adicional — por
  isso o **custo de produção estabiliza em torno de R$ 145–151 M** enquanto a demanda
  continua subindo.
- **O gargalo ativo é a capacidade de máquina (R4)**, não a armazenagem: os preços-sombra
  de armazenagem (`gamma_armazenagem`) são praticamente zero em todo o horizonte, enquanto
  o preço-sombra da demanda (`pi_demanda`) atinge o valor Big-M exatamente onde ocorrem as
  vendas perdidas.
- **A logística é barata e secundária** (≈ R$ 0,3–0,7 M contra > R$ 140 M de produção):
  a rede produz majoritariamente local, usando transferências entre plantas sobretudo para
  cobrir os ~10% de pedidos com formato incompatível.

> Como a demanda não atendida é penalizada com Big-M (R$ 1.000.000/lata), a coluna
> `custo_total` explode assim que surgem vendas perdidas. Compare cenários estressados pela
> **taxa de atendimento** e pelos componentes físicos de custo, não pelo custo total.

Arquivos de saída em `resultados/`:

- `resultados_Nenhuma_cam80_fator1.0_*.csv` — resumo consolidado (uma linha por cenário)
- `detalhe_ocupacao_<N>.csv` — solução por SKU/planta/linha/dia
- `duals_capacidade_ocupacao_<N>.csv` — preços-sombra de hora-máquina (μ) e armazenagem (γ)
- `duals_demanda_ocupacao_<N>.csv` — preços-sombra da demanda (π) e flags de saturação

### Análise de sensibilidade

O painel de controle em `modelo/modelagem.jl` expõe três eixos de perturbação para análise
de cenários:

- `fabrica_quebrada` — desliga uma planta (0 horas-máquina) para revelar plantas críticas;
- `limite_caminhoes` — reduz a frota de caminhões (ex.: 80 → 40 → 10) para estressar a logística;
- `fator_demanda` — escala toda a demanda (1.0 → 2.0 → 3.0) para simular choques de demanda.

Veja a seção 10 de `relatorio/otimizacao.pdf` para um plano de experimentos sugerido.

---

### Autores / Authors

Projeto desenvolvido para a disciplina de **Otimização Linear** — UNIFESP.
