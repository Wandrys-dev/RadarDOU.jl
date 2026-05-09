"""
    RadarDOU

SDK oficial Julia para a API do Radar DOU - Sistema de Monitoramento do Diario Oficial da Uniao.

# Exemplo
```julia
using RadarDOU

# Carregue a chave de variavel de ambiente
api_key = ENV["RADAR_API_KEY"]
client = RadarDOUClient(api_key)

# Pelo menos um filtro e obrigatorio
resultado = buscar(client; date_from="2026-05-01", limit=10)
println("Total: ", resultado["pagination"]["total"])

# Detalhes de uma publicacao (texto completo)
pub = obter_publicacao(client, resultado["data"][1]["id"])
println(pub["texto_puro"])

close(client)
```
"""
module RadarDOU

using HTTP
using JSON3
using SHA
using Dates

export RadarDOUClient, buscar, obter_publicacao,
       listar_alertas, criar_alerta,
       listar_favoritos, adicionar_favorito, remover_favorito,
       listar_colecoes, criar_colecao, vocabulario,
       validar_sessao

# Excecoes
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

const SDK_VERSION = "1.0.1"
const DEFAULT_BASE_URL = "https://www.radar-dou.com/api/v1"
const DEFAULT_TIMEOUT = 30

"""
    RadarDOUClient(api_key; base_url=..., timeout=30, auto_session=true)

Cliente para a API do Radar DOU.
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
                "API Key e obrigatoria. Obtenha em https://www.radar-dou.com/api-keys",
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
                # Outros erros sao ignorados (chave funciona sem sessao)
            end
        end

        client
    end
end

function generate_fingerprint()
    info = join([
        gethostname(),
        Sys.KERNEL,
        Sys.ARCH,
        string(Sys.CPU_THREADS)
    ], "|")
    bytes2hex(sha256(info))[1:32]
end

function _request(
    client::RadarDOUClient,
    method::Symbol,
    endpoint::String;
    body::Union{Dict, Nothing} = nothing,
    query::Union{Dict, Nothing} = nothing
)
    url = client.base_url * endpoint

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
            error("Metodo HTTP nao suportado: $method")
        end

        return JSON3.read(String(response.body))

    catch e
        if e isa HTTP.ExceptionRequest.StatusError
            status = e.status
            data = try
                JSON3.read(String(e.response.body))
            catch
                Dict("error" => "Erro desconhecido")
            end
            handle_error(status, data)
        else
            throw(RadarDOUError("Erro de conexao: $(e)", "CONNECTION_ERROR", nothing))
        end
    end
end

function handle_error(status::Int, data)
    # Backend usa "error" como chave principal
    message = get(data, :error, get(data, :message, "Erro desconhecido"))
    code = get(data, :code, "UNKNOWN_ERROR")

    if status == 400
        throw(RadarDOUError(message, code, get(data, :details, nothing)))
    elseif status == 401
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
            end
        end
    end
end

"""
    buscar(client; query=nothing, date_from=nothing, date_to=nothing, secao=nothing, tipo=nothing, page=1, limit=20)

Busca publicacoes no DOU. Pelo menos um filtro e obrigatorio.

# Exemplo
```julia
buscar(client; date_from="2026-05-01", limit=10)
buscar(client; query="licitacao", date_from="2026-05-01")
buscar(client; query="edital", secao="DO3", tipo="Edital",
        date_from="2026-01-01", date_to="2026-05-08")
```
"""
function buscar(
    client::RadarDOUClient;
    query::Union{String, Nothing} = nothing,
    date_from::Union{String, Nothing} = nothing,
    date_to::Union{String, Nothing} = nothing,
    secao::Union{String, Nothing} = nothing,
    tipo::Union{String, Nothing} = nothing,
    page::Int = 1,
    limit::Int = 20
)
    if isnothing(query) && isnothing(date_from) && isnothing(date_to) &&
       isnothing(secao) && isnothing(tipo)
        throw(RadarDOUError(
            "Pelo menos um filtro e obrigatorio: query, date_from, date_to, secao ou tipo.",
            "FILTER_REQUIRED",
            nothing
        ))
    end

    q = Dict("page" => page, "limit" => min(limit, 100))
    !isnothing(query)     && (q["query"]     = query)
    !isnothing(date_from) && (q["date_from"] = date_from)
    !isnothing(date_to)   && (q["date_to"]   = date_to)
    !isnothing(secao)     && (q["secao"]     = secao)
    !isnothing(tipo)      && (q["tipo"]      = tipo)

    _request(client, :GET, "/publications"; query = q)
end

"""
    obter_publicacao(client, id)

Detalhes completos da publicacao (texto_html e texto_puro inclusos).
"""
function obter_publicacao(client::RadarDOUClient, id)
    _request(client, :GET, "/publications/$id")
end

"""
    listar_alertas(client; page=1, limit=20, active_only=false)
"""
function listar_alertas(
    client::RadarDOUClient;
    page::Int = 1,
    limit::Int = 20,
    active_only::Bool = false
)
    q = Dict("page" => page, "limit" => min(limit, 100))
    active_only && (q["active"] = "true")
    _request(client, :GET, "/alerts"; query = q)
end

"""
    criar_alerta(client, name, search_criteria; kwargs...)

# Exemplo
```julia
criar_alerta(client, "Concursos TI",
    Dict("query" => "desenvolvedor", "secao" => "DO3");
    frequency="daily")
```
"""
function criar_alerta(
    client::RadarDOUClient,
    name::String,
    search_criteria::Dict;
    description::Union{String, Nothing} = nothing,
    frequency::String = "daily",
    email_notification::Bool = true,
    sound_alert::Bool = false
)
    body = Dict(
        "name" => name,
        "searchCriteria" => search_criteria,
        "frequency" => frequency,
        "emailNotification" => email_notification,
        "soundAlert" => sound_alert
    )
    !isnothing(description) && (body["description"] = description)
    _request(client, :POST, "/alerts"; body = body)
end

"""
    listar_favoritos(client; page=1, limit=20)
"""
function listar_favoritos(client::RadarDOUClient; page::Int = 1, limit::Int = 20)
    _request(client, :GET, "/favorites";
             query = Dict("page" => page, "limit" => min(limit, 100)))
end

"""
    adicionar_favorito(client, publication_id; notes=nothing)
"""
function adicionar_favorito(
    client::RadarDOUClient,
    publication_id::String;
    notes::Union{String, Nothing} = nothing
)
    body = Dict("publicationId" => publication_id)
    !isnothing(notes) && (body["notes"] = notes)
    _request(client, :POST, "/favorites"; body = body)
end

"""
    remover_favorito(client, publication_id)
"""
function remover_favorito(client::RadarDOUClient, publication_id::String)
    _request(client, :DELETE, "/favorites";
             query = Dict("publicationId" => publication_id))
end

"""
    listar_colecoes(client)
"""
function listar_colecoes(client::RadarDOUClient)
    _request(client, :GET, "/collections")
end

"""
    criar_colecao(client, name; description=nothing)
"""
function criar_colecao(
    client::RadarDOUClient,
    name::String;
    description::Union{String, Nothing} = nothing
)
    body = Dict("name" => name)
    !isnothing(description) && (body["description"] = description)
    _request(client, :POST, "/collections"; body = body)
end

"""
    vocabulario(client)

Lista vocabulario do DOU (secoes, tipos de ato).
"""
function vocabulario(client::RadarDOUClient)
    _request(client, :GET, "/vocabulary")
end

"""
    validar_sessao(client)
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

Encerra a sessao e libera recursos.
"""
function Base.close(client::RadarDOUClient)
    if !isnothing(client.heartbeat_task)
        try
            schedule(client.heartbeat_task, InterruptException(); error=true)
        catch
        end
        client.heartbeat_task = nothing
    end

    if !isnothing(client.session_id)
        try
            _request(client, :POST, "/session/end"; body = Dict(
                "session_id" => client.session_id
            ))
        catch
        end
        client.session_id = nothing
    end
end

function Base.show(io::IO, client::RadarDOUClient)
    print(io, "RadarDOUClient(base_url=\"$(client.base_url)\", session_active=$(client.session_id !== nothing))")
end

end # module
