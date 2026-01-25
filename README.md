# RadarDOU.jl

SDK oficial Julia para a API do [Radar DOU](https://radar-dou.com) - Sistema de Monitoramento do Diário Oficial da União.

## Requisitos

- Julia 1.6+
- API Key válida de assinante do Radar DOU

## Instalação

```julia
# Adicionar o pacote (quando disponível no registry)
# using Pkg
# Pkg.add("RadarDOU")

# Ou instalar do GitHub
using Pkg
Pkg.add(url="https://github.com/radar-dou/RadarDOU.jl")
```

## Início Rápido

```julia
using RadarDOU

# Criar cliente com sua API Key
client = RadarDOUClient("sua_api_key_aqui")

# Buscar publicações
resultado = buscar(client, "licitação")
println("Encontrados $(resultado[:total]) resultados")

# Ao finalizar, encerre a sessão
close(client)
```

## Funcionalidades

### Busca de Publicações

```julia
# Busca simples
resultado = buscar(client, "edital")

# Busca com filtros
resultado = buscar(
    client,
    "pregão eletrônico";
    data_inicio = "2024-01-01",
    data_fim = "2024-12-31",
    orgao = "Ministério da Educação",
    tipo = "edital",
    secao = 3,
    pagina = 1,
    limite = 50
)

# Obter publicação específica
publicacao = obter_publicacao(client, "abc123")
```

### Gerenciamento de Alertas

```julia
# Listar alertas
alertas = listar_alertas(client)

# Criar alerta
alerta = criar_alerta(
    client,
    "Monitorar Licitações Saúde",
    ["licitação", "pregão"];
    orgaos = ["Ministério da Saúde"],
    email_notificacao = true
)

# Atualizar alerta
atualizar_alerta(client, alerta[:id]; nome = "Novo Nome")

# Excluir alerta
excluir_alerta(client, alerta[:id])
```

### Informações de Uso

```julia
# Ver uso da API
uso = obter_uso(client)
println("Requisições hoje: $(uso[:requisicoes_hoje])")
println("Limite por hora: $(uso[:limite_hora])")

# Informações da conta
conta = obter_conta(client)
println("Plano: $(conta[:plano])")
```

## Controle de Sessão

O SDK implementa controle automático de sessão para garantir que sua API Key seja usada apenas por você:

- **Fingerprint de dispositivo**: Identifica unicamente seu computador
- **Heartbeat automático**: Mantém sua sessão ativa em background
- **Detecção de uso compartilhado**: Impede que outros usem sua API Key simultaneamente

### Tratamento de Erros

```julia
using RadarDOU

try
    client = RadarDOUClient("sua_api_key")
    resultado = buscar(client, "teste")
catch e
    if e isa RadarDOU.AuthenticationError
        println("Erro de autenticação: $(e.message)")
    elseif e isa RadarDOU.SessionConflictError
        println("Conflito de sessão: $(e.message)")
        println("IP ativo: $(e.active_ip)")
    elseif e isa RadarDOU.RateLimitError
        println("Limite atingido: $(e.message)")
    else
        println("Erro: $e")
    end
end
```

## Limites por Plano

| Plano | Requisições/hora | Sessões Simultâneas |
|-------|------------------|---------------------|
| Profissional | 1.000 | 1 |
| Premium | 5.000 | 3 |
| Enterprise | Ilimitado | Ilimitado |

## Obtenha sua API Key

Para usar este SDK, você precisa de uma API Key válida:

1. Acesse [radar-dou.com](https://radar-dou.com)
2. Crie uma conta ou faça login
3. Assine um plano
4. Gere sua API Key em [Configurações > API Keys](https://radar-dou.com/api-keys)

## Suporte

- 📧 Email: suporte@radar-dou.com
- 📖 Documentação: [radar-dou.com/docs](https://radar-dou.com/docs)
- 🐛 Issues: [GitHub Issues](https://github.com/radar-dou/RadarDOU.jl/issues)

## Licença

MIT License - veja [LICENSE](LICENSE) para detalhes.
