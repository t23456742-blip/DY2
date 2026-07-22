import SwiftUI

struct RootTabView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem {
                    Label("瘦身", systemImage: "flame.fill")
                }
                .tag(0)

            RulesView()
                .tabItem {
                    Label("规则", systemImage: "checklist")
                }
                .tag(1)
        }
        .accentColor(Color(red: 0.15, green: 0.85, blue: 0.78))
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }
}
