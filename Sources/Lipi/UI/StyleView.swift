import AppKit
import SwiftUI

struct StyleView: View {
    @ObservedObject var model: AppModel
    @ViewState private var category: AppCategory = .personal
    @Namespace private var tabs

    private let sample = "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Style", subtitle: "Lipi picks the style from the app you're typing in. Applies to text in English letters.")
                tabBar
                banner
                HStack(alignment: .top, spacing: 16) {
                    ForEach(WritingStyle.allCases) { style in styleCard(style) }
                }
            }
            .padding(32)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(AppCategory.allCases) { c in
                Button {
                    withAnimation(.snappy) { category = c }
                } label: {
                    VStack(spacing: 8) {
                        Text(c.title)
                            .font(.system(size: 13, weight: category == c ? .semibold : .regular))
                            .foregroundStyle(category == c ? .primary : .secondary)
                        ZStack {
                            Capsule().fill(.clear).frame(height: 2)
                            if category == c { Capsule().fill(Brand.accent).frame(height: 2).matchedGeometryEffect(id: "tab", in: tabs) }
                        }
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var banner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(category.headline).font(.system(size: 22, weight: .semibold, design: .serif))
                Text(category == .other ? "Any app not listed in the other tabs." : "Detected automatically, including web versions in your browser.")
                    .font(.system(size: 12)).opacity(0.85)
            }
            Spacer()
            HStack(spacing: -10) {
                ForEach(icons, id: \.self) { image in
                    Image(nsImage: image).resizable().frame(width: 44, height: 44)
                        .padding(4)
                        .glassEffect(.regular, in: .circle)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(
            LinearGradient(colors: [Brand.accent2.opacity(0.85), Color.indigo.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private var icons: [NSImage] {
        let ids = StyleEngine.apps[category] ?? []
        return ids.compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        .prefix(4)
        .map { $0 }
    }

    private func styleCard(_ style: WritingStyle) -> some View {
        let selected = model.styles[category] == style
        return Button {
            withAnimation(.snappy) { model.setStyle(style, for: category) }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(style.title).font(.system(size: 16, weight: .semibold))
                    Text(style.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Text(StyleEngine.apply(style, to: sample))
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.gradient.opacity(selected ? 1 : 0.7), in: UnevenRoundedRectangle(
                        topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous))
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
            .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Brand.accent : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
