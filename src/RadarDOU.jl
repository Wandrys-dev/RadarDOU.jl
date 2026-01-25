"""
    RadarDOU

SDK oficial Julia para a API do Radar DOU - Sistema de Monitoramento do Diário Oficial da União.

# Exemplo de uso
```julia
using RadarDOU

# Criar cliente
client = RadarDOUClient("sua_api_key")

# Buscar publicações
resultado = buscar(client, "licitação")

# Encerrar sessão
close(client)
```
"""
module RadarDOU

using HTTP
using JSON3
using SHA
using Dates

export RadarDOUClient, buscar, obter_publicacao, listar_alertas, criar_alerta,
       atualizar_alerta, excluir_alerta, obter_uso, obter_conta, validar_sessao

# Exceções
struct RadarDOUError <: Exception
    message::String
    code::String
    details::Union{Dict, Nothing}
end

struct AuthenticationError <: Exception
    message::String
    code::String
end

struct SessionConflictError <: Exception
    message::String
    active_ip::Union{String, Nothing}
end

struct RateLimitError <: Exception
    message::String
    limit::Union{Int, Nothing}
    reset_at::Union{String, Nothing}
end

Base.showerror(io::IO, e::RadarDOUError) = print(io, "RadarDOUError: $(e.message) ($(e.code))")
Base.showerror(io::IO, e::AuthenticationError) = print(io, "AuthenticationError: $(e.message)")
Base.showerror(io::IO, e::SessionConflictError) = print(io, "SessionConflictError: $(e.message)")
Base.showerror(io::IO, e::RateLimitError) = print(io, "RateLimitError: $(e.message)")

const SDK_VERSION = "1.0.0"
const DEFAULT_BASE_URL = "https://api.radar-dou.com/v1"
const DEFAULT_TIMEOUT = 30

"""
    RadarDOUClient

Cliente para a API do Radar DOU.

# Argumentos
- `api_key::String`: Sua API Key de assinante
- `base_url::String`: URL base da API (padrão: https://api.radar-dou.com/v1)
- `timeout::Int`: Timeout em segundos (padrão: 30)
- `auto_session::Bool`: Iniciar sessão automaticamente (padrão: true)
"""
mutable struct RadarDOUClient
    api_key::String
    base_url::String
    timeout::Int
    session_id::Union{String, Nothing}
    device_fingerprint::Union{String, Nothing}
    heartbeat_task::Union{Task, Nothing}

    function RadarDOUClient(
        api_key::String;
        base_url::String = DEFAULT_BASE_URL,
        timeout::Int = DEFAULT_TIMEOUT,
        auto_session::Bool = true
    )
        if isempty(api_key)
            throw(AuthenticationError(
                "API Key é obrigatória. Obtenha sua chave em https://radar-dou.com/api-keys",
                "API_KEY_REQUIRED"
            ))
        end

        client = new(
            api_key,
            rstrip(base_url, '/'),
            timeout,
            nothing,
            nothing,
            nothing
        )

        if auto_session
            try
                start_session!(client)
            catch e
                if e isa SessionConflictError
                    rethrow()
                end
                # Outros erros são ignorados no startup
            end
        end

        client
    end
end

# Gera fingerprint do dispositivo
function generate_fingerprint()
    info = join([
        gethostname(),
        Sys.KERNEL,
        Sys.ARCH,
        string(Sys.CPU_THREADS)
    ], "|")
    bytes2hex(sha256(info))[1:32]
end

# Faz requisição para a API
function _request(
    client::RadarDOUClient,
    method::Symbol,
    endpoint::String;
    body::Union{Dict, Nothing} = nothing,
    query::Union{Dict, Nothing} = nothing
)
    url = client.base_url * endpoint

    # Adiciona query params
    if !isnothing(query) && !isempty(query)
        params = join(["$k=$(HTTP.escapeuri(string(v)))" for (k, v) in query if !isnothing(v)], "&")
        url *= "?" * params
    end

    headers = [
        "Authorization" => "Bearer $(client.api_key)",
        "Content-Type" => "application/json",
        "User-Agent" => "RadarDOU-Julia/$SDK_VERSION",
        "X-SDK-Version" => SDK_VERSION
    ]

    try
        response = if method == :GET
            HTTP.get(url, headers; readtimeout=client.timeout)
        elseif method == :POST
            body_json = isnothing(body) ? "" : JSON3.write(body)
            HTTP.post(url, headers, body_json; readtimeout=client.timeout)
        elseif method == :PATCH
            body_json = isnothing(body) ? "" : JSON3.write(body)
            HTTP.patch(url, headers, body_json; readtimeout=client.timeout)
        elseif method == :DELETE
            HTTP.delete(url, headers; readtimeout=client.timeout)
        else
            error("Método HTTP não suportado: $method")
        end

        return JSON3.read(String(response.body))

    catch e
        if e isa HTTP.ExceptionRequest.StatusError
            status = e.status
            data = try
                JSON3.read(String(e.response.body))
            catch
                Dict("message" => "Erro desconhecido")
            end

            handle_error(status, data)
        else
            throw(RadarDOUError("Erro de conexão: $(e)", "CONNECTION_ERROR", nothing))
        end
    end
end

function handle_error(status::Int, data)
    message = get(data, :message, "Erro desconhecido")
    code = get(data, :code, "UNKNOWN_ERROR")

    if status == 401
        throw(AuthenticationError(message, code))
    elseif status == 403
        if code == "SESSION_CONFLICT"
            throw(SessionConflictError(message, get(data, :active_ip, nothing)))
        end
        throw(AuthenticationError(message, code))
    elseif status == 429
        throw(RateLimitError(
            message,
            get(data, :limit, nothing),
            get(data, :reset_at, nothing)
        ))
    else
        throw(RadarDOUError(message, code, get(data, :details, nothing)))
    end
end

# Inicia sessão
function start_session!(client::RadarDOUClient)
    client.device_fingerprint = generate_fingerprint()

    device_info = Dict(
        "hostname" => gethostname(),
        "os" => string(Sys.KERNEL),
        "arch" => string(Sys.ARCH),
        "julia_version" => string(VERSION),
        "sdk_version" => SDK_VERSION
    )

    result = _request(client, :POST, "/session/start"; body = Dict(
        "device_fingerprint" => client.device_fingerprint,
        "device_info" => device_info
    ))

    client.session_id = result[:session_id]

    # Inicia heartbeat em background
    interval = get(result, :heartbeat_interval, 30)
    start_heartbeat!(client, interval)

    result
end

function start_heartbeat!(client::RadarDOUClient, interval::Int)
    client.heartbeat_task = @async begin
        while !isnothing(client.session_id)
            sleep(interval)
            try
                _request(client, :POST, "/session/heartbeat"; body = Dict(
                    "session_id" => client.session_id,
                    "device_fingerprint" => client.device_fingerprint
                ))
            catch
                # Ignora erros de heartbeat
            end
        end
    end
end

"""
    buscar(client, termo; kwargs...)

Busca publicações no DOU.

# Argumentos
- `client::RadarDOUClient`: Cliente RadarDOU
- `termo::String`: Termo de busca
- `data_inicio::Union{String, Nothing}`: Data inicial (YYYY-MM-DD)
- `data_fim::Union{String, Nothing}`: Data final (YYYY-MM-DD)
- `orgao::Union{String, Nothing}`: Filtrar por órgão
- `tipo::Union{String, Nothing}`: Tipo de publicação
- `secao::Union{Int, Nothing}`: Seção do DOU (1, 2 ou 3)
- `pagina::Int`: Número da página (padrão: 1)
- `limite::Int`: Quantidade por página (padrão: 20, máx: 100)

# Retorna
Dict com resultados da busca
"""
function buscar(
    client::RadarDOUClient,
    termo::String;
    data_inicio::Union{String, Nothing} = nothing,
    data_fim::Union{String, Nothing} = nothing,
    orgao::Union{String, Nothing} = nothing,
    tipo::Union{String, Nothing} = nothing,
    secao::Union{Int, Nothing} = nothing,
    pagina::Int = 1,
    limite::Int = 20
)
    query = Dict(
        "q" => termo,
        "pagina" => pagina,
        "limite" => min(limite, 100)
    )

    !isnothing(data_inicio) && (query["data_inicio"] = data_inicio)
    !isnothing(data_fim) && (query["data_fim"] = data_fim)
    !isnothing(orgao) && (query["orgao"] = orgao)
    !isnothing(tipo) && (query["tipo"] = tipo)
    !isnothing(secao) && (query["secao"] = secao)

    _request(client, :GET, "/search"; query = query)
end

"""
    obter_publicacao(client, id)

Obtém detalhes de uma publicação específica.
"""
function obter_publicacao(client::RadarDOUClient, id::String)
    _request(client, :GET, "/publicacoes/$id")
end

"""
    listar_alertas(client)

Lista todos os alertas configurados.
"""
function listar_alertas(client::RadarDOUClient)
    _request(client, :GET, "/alertas")
end

"""
    criar_alerta(client, nome, termos; kwargs...)

Cria um novo alerta de monitoramento.
"""
function criar_alerta(
    client::RadarDOUClient,
    nome::String,
    termos::Vector{String};
    orgaos::Union{Vector{String}, Nothing} = nothing,
    tipos::Union{Vector{String}, Nothing} = nothing,
    secoes::Union{Vector{Int}, Nothing} = nothing,
    email_notificacao::Bool = true
)
    body = Dict(
        "nome" => nome,
        "termos" => termos,
        "email_notificacao" => email_notificacao
    )

    !isnothing(orgaos) && (body["orgaos"] = orgaos)
    !isnothing(tipos) && (body["tipos"] = tipos)
    !isnothing(secoes) && (body["secoes"] = secoes)

    _request(client, :POST, "/alertas"; body = body)
end

"""
    atualizar_alerta(client, id; kwargs...)

Atualiza um alerta existente.
"""
function atualizar_alerta(client::RadarDOUClient, id::String; kwargs...)
    body = Dict(string(k) => v for (k, v) in kwargs)
    _request(client, :PATCH, "/alertas/$id"; body = body)
end

"""
    excluir_alerta(client, id)

Exclui um alerta.
"""
function excluir_alerta(client::RadarDOUClient, id::String)
    _request(client, :DELETE, "/alertas/$id")
end

"""
    obter_uso(client)

Obtém informações de uso da API.
"""
function obter_uso(client::RadarDOUClient)
    _request(client, :GET, "/uso")
end

"""
    obter_conta(client)

Obtém informações da conta.
"""
function obter_conta(client::RadarDOUClient)
    _request(client, :GET, "/conta")
end

"""
    validar_sessao(client)

Valida se a sessão atual é válida.
"""
function validar_sessao(client::RadarDOUClient)
    if isnothing(client.session_id)
        return false
    end

    try
        result = _request(client, :POST, "/session/validate"; body = Dict(
            "session_id" => client.session_id,
            "device_fingerprint" => client.device_fingerprint
        ))
        return get(result, :valid, false)
    catch
        return false
    end
end

"""
    Base.close(client)

Encerra a sessão e libera recursos.
"""
function Base.close(client::RadarDOUClient)
    # Para o heartbeat
    if !isnothing(client.heartbeat_task)
        try
            schedule(client.heartbeat_task, InterruptException(); error=true)
        catch
        end
        client.heartbeat_task = nothing
    end

    # Encerra sessão
    if !isnothing(client.session_id)
        try
            _request(client, :POST, "/session/end"; body = Dict(
                "session_id" => client.session_id
            ))
        catch
            # Ignora erros ao encerrar
        end
        client.session_id = nothing
    end
end

function Base.show(io::IO, client::RadarDOUClient)
    print(io, "RadarDOUClient(base_url=\"$(client.base_url)\", session_active=$(client.session_id !== nothing))")
end

end # module
