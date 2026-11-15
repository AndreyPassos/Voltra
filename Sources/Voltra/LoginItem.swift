import Foundation
import ServiceManagement

enum LoginItemState { case disabled, enabled, requiresApproval, unavailable }
protocol LoginItemManaging {
    var status: LoginItemState { get }
    func register() throws
    func unregister() throws
}
struct SystemLoginItem: LoginItemManaging {
    var status: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        default: return .unavailable
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
final class LoginItemController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var message: String?
    private let service: any LoginItemManaging
    init(service: any LoginItemManaging = SystemLoginItem()) { self.service = service; refresh() }
    func refresh() {
        let status = service.status
        enabled = status == .enabled || status == .requiresApproval
        switch status {
        case .requiresApproval: message = "Ative o Voltra em Ajustes do Sistema > Geral > Itens de Início."
        case .unavailable: message = "O macOS ainda não identificou o item de início. Ative a opção para tentar registrá-lo."
        default: message = nil
        }
    }
    func setEnabled(_ value: Bool) {
        do {
            if value { try service.register() } else { try service.unregister() }
            refresh()
        } catch {
            refresh()
            message = VoltraLanguage.format("Não foi possível alterar a inicialização: %@", error.localizedDescription)
        }
    }
}
