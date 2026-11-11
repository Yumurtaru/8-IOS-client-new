import SwiftUI
import WidgetKit

//  Точка входа расширения YumurtaWidgets (project.extensions.yml).

@main
struct YumurtaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ActiveOrderWidget()
        BonusWidget()
        if #available(iOS 16.1, *) {
            OrderLiveActivityWidget()
        }
    }
}
