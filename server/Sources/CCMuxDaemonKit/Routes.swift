import CCMuxCore
import Foundation
import Hummingbird

extension HealthResponse: @retroactive ResponseEncodable {}
extension AccountListResponse: @retroactive ResponseEncodable {}
extension RemoteAccount: @retroactive ResponseEncodable {}
extension TokenGrant: @retroactive ResponseEncodable {}
extension RemoteUsage: @retroactive ResponseEncodable {}
extension LoginStartResponse: @retroactive ResponseEncodable {}

public enum Routes {
    public static func build(registry: AccountRegistry, credential: BasicAuthCredential) -> Router<BasicRequestContext> {
        let router = Router()
        router.middlewares.add(BasicAuthMiddleware(credential: credential))

        router.get("\(ServerAPI.prefix)/health") { _, _ in
            await registry.health()
        }

        router.get("\(ServerAPI.prefix)/accounts") { _, _ in
            AccountListResponse(accounts: await registry.list())
        }

        router.get("\(ServerAPI.prefix)/accounts/:id/token") { _, context in
            let id = try context.parameters.require("id")
            guard let grant = await registry.token(for: id) else {
                throw HTTPError(.notFound, message: "no usable credential for \(id)")
            }
            return grant
        }

        router.get("\(ServerAPI.prefix)/accounts/:id/usage") { _, context in
            let id = try context.parameters.require("id")
            guard let usage = await registry.usageSnapshot(for: id) else {
                throw HTTPError(.notFound, message: "no usage recorded for \(id)")
            }
            return usage
        }

        router.post("\(ServerAPI.prefix)/login/start") { request, context in
            let body = try await request.decode(as: LoginStartRequest.self, context: context)
            return await registry.startLogin(body)
        }

        router.post("\(ServerAPI.prefix)/login/finish") { request, context in
            let body = try await request.decode(as: LoginFinishRequest.self, context: context)
            do {
                return try await registry.finishLogin(body)
            } catch {
                throw HTTPError(.badRequest, message: error.localizedDescription)
            }
        }

        router.post("\(ServerAPI.prefix)/accounts/adopt") { request, context in
            let body = try await request.decode(as: AdoptRequest.self, context: context)
            do {
                return try await registry.adopt(body)
            } catch {
                throw HTTPError(.badRequest, message: error.localizedDescription)
            }
        }

        router.delete("\(ServerAPI.prefix)/accounts/:id") { _, context in
            let id = try context.parameters.require("id")
            do {
                try await registry.remove(id)
            } catch {
                throw HTTPError(.notFound, message: error.localizedDescription)
            }
            return Response(status: .noContent)
        }

        return router
    }
}
