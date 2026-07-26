import SwiftUI

struct RootTabView: View {
    @StateObject private var cleanModel = CleanViewModel()
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ContentView(model: cleanModel)
                .tabItem {
                    Label("助手", systemImage: "sparkles")
                }
                .tag(0)

            RulesView(cleanModel: cleanModel)
                .tabItem {
                    Label("工具", systemImage: "wrench.and.screwdriver.fill")
                }
                .tag(1)
        }
        .accentColor(Color(red: 0.15, green: 0.85, blue: 0.78))
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .onAppear {
            cleanModel.bootstrap()
        }
    }
}
