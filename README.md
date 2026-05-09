# RadarDOU.jl

SDK oficial Julia para a API do [Radar DOU](https://www.radar-dou.com) — Sistema de Monitoramento do Diário Oficial da União.

## Requisitos

- Julia >= 1.6
- API Key válida de assinante (gere em [www.radar-dou.com/api-keys](https://www.radar-dou.com/api-keys))

## Instalação

```julia
using Pkg
Pkg.add(url="https://github.com/Wandrys-dev/RadarDOU.jl")
```

## Início rápido

```julia
using RadarDOU

# Carregue a chave de variavel de ambiente
api_key = ENV["RADAR_API_KEY"]
client = RadarDOUClient(api_key)

# IMPORTANTE: pelo menos um filtro e obrigatorio
resultado = buscar(client; date_from="2026-05-01", limit=10)

println("Total: ", resultado["pagination"]["total"])
for pub in resultado["data"]
    println("[$(pub["secao_codigo"])] $(pub["titulo"])")
end

close(client)
```

## Buscar publicações

```julia
# Por data
buscar(client; date_from="2026-05-01", date_to="2026-05-08")

# Por palavra-chave
buscar(client; query="licitação", date_from="2026-05-01")

# Filtros combinados
buscar(client;
    query="edital",
    secao="DO3",          # DO1, DO2, DO3 ou Extra
    tipo="Edital",        # Portaria, Edital, Despacho, etc.
    date_from="2026-01-01",
    date_to="2026-05-08",
    page=1,
    limit=50)              # máx 100
```

**Filtro mínimo obrigatório.** Chamar `buscar(client)` sem nenhum filtro lança
`RadarDOUError("FILTER_REQUIRED")`. Isso evita scans amplos da tabela (~7M+ linhas).

## Detalhes de uma publicação

A listagem retorna apenas `texto_resumo`. Para o **texto completo**:

```julia
ids = [p["id"] for p in resultado["data"]]
for id in ids
    pub = obter_publicacao(client, id)
    println(pub["titulo"])
    println(pub["texto_puro"])    # texto completo
end
```

## Alertas

```julia
# Listar
alertas = listar_alertas(client)

# Criar
criar_alerta(client, "Concursos TI",
    Dict("query" => "desenvolvedor", "secao" => "DO3");
    frequency="daily",
    email_notification=true)
```

## Favoritos e coleções

```julia
listar_favoritos(client)
adicionar_favorito(client, "12345")
remover_favorito(client, "12345")

listar_colecoes(client)
criar_colecao(client, "Editais 2026")
```

## Vocabulário

```julia
vocab = vocabulario(client)  # seções e tipos disponíveis
```

## Tratamento de erros

```julia
using RadarDOU

try
    client = RadarDOUClient(ENV["RADAR_API_KEY"])
    resultado = buscar(client; date_from="2026-05-01")
catch e
    if e isa AuthenticationError
        println("Chave invalida ou expirada")
    elseif e isa SessionConflictError
        println("Outra sessao ja ativa em $(e.active_ip)")
    elseif e isa RateLimitError
        println("Rate limit. Reset em $(e.reset_at)")
    elseif e isa RadarDOUError
        println("Erro $(e.code): $(e.message)")
    else
        rethrow()
    end
end
```

## Limites por plano

| Plano | Rate limit | Sessões | Chaves |
|-------|-----------|---------|--------|
| Trial (5 dias) | 100 req/h | 1 | 1 |
| Profissional | 1.000 req/h | 1 | 2 |
| Premium | 5.000 req/h | 3 | 5 |
| Empresarial | 10.000 req/h | 10 | 10 |

## Licença

MIT
