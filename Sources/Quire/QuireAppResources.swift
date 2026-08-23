import Foundation
import QuireCore

/// App 目标的资源 bundle（见 QuireCore.ResourceBundle）
enum QuireAppResources {
    static let bundle: Bundle = ResourceBundle.locate("Quire_Quire") { Bundle.module }
}
