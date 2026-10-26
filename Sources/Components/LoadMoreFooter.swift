//
//  LoadMoreFooter.swift — подвал ленты с догрузкой страниц (meta.has_more, волна А3).
//  Используют: ListingView (заведения), OrdersView (история), NotificationsView.
//

import SwiftUI

/// Подвал ленты с догрузкой: пока виден — сам просит следующую страницу; ключ
/// page перезапускает запрос, если после догрузки подвал всё ещё на экране.
/// После сбоя — кнопка «Показать ещё», чтобы не крутить запросы без связи.
/// Внутри LazyVStack: в обычном VStack onAppear сработал бы сразу у всех строк.
struct LoadMoreFooter: View {
    let page: Int
    let failed: Bool
    let onLoadMore: () async -> Void
    var body: some View {
        Group {
            if failed {
                Button { Task { await onLoadMore() } } label: {
                    Text("Показать ещё").font(.system(size: 14.5, weight: .heavy)).foregroundStyle(YMColor.accent)
                        .padding(.horizontal, YMSpace.xxl).padding(.vertical, 10)
                        .background(YMColor.accent.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                // Отдельная задача: если подвал уедет с экрана посреди запроса, .task
                // отменился бы, и вместе с ним — уже отправленная догрузка.
                ProgressView().task(id: page) { await Task { await onLoadMore() }.value }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
