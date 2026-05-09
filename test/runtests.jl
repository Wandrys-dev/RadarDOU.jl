using RadarDOU
using Test

@testset "RadarDOU.jl" begin
    @testset "Símbolos exportados" begin
        # Cliente
        @test isdefined(RadarDOU, :RadarDOUClient)

        # Funções principais
        @test isdefined(RadarDOU, :buscar)
        @test isdefined(RadarDOU, :obter_publicacao)

        # Alertas, favoritos, coleções, vocabulário
        @test isdefined(RadarDOU, :listar_alertas)
        @test isdefined(RadarDOU, :criar_alerta)
        @test isdefined(RadarDOU, :listar_favoritos)
        @test isdefined(RadarDOU, :adicionar_favorito)
        @test isdefined(RadarDOU, :listar_colecoes)
        @test isdefined(RadarDOU, :criar_colecao)
        @test isdefined(RadarDOU, :vocabulario)

        # Erros tipados
        @test isdefined(RadarDOU, :RadarDOUError)
        @test isdefined(RadarDOU, :AuthenticationError)
        @test isdefined(RadarDOU, :RateLimitError)
        @test isdefined(RadarDOU, :SessionConflictError)
    end

    @testset "buscar() valida filtro mínimo" begin
        # Cliente fake só pra testar a validação local (não faz HTTP)
        client = RadarDOUClient("fake_key_apenas_para_teste_local")
        @test_throws RadarDOUError buscar(client)
    end
end
