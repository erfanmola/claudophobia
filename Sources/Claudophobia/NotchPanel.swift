import AppKit
import SwiftUI

// MARK: - Screen helpers

extension NSScreen {
   /// True on Macs with a camera housing (notch) cut into the menu bar.
   var hasNotch: Bool { safeAreaInsets.top > 0 }
}

// MARK: - Panel background (mouse tracking)

/// Plain, transparent NSView that reports mouse enter/exit so the card can
/// collapse the moment the cursor leaves it. No visual-effect material: the
/// notch card is solid black (an extension of the camera housing), not glass.
final class NotchBackgroundView: NSView {
   var onMouseEntered: (() -> Void)?
   var onMouseExited: (() -> Void)?

   override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      let area = NSTrackingArea(
         rect: bounds,
         options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
         owner: self,
         userInfo: nil
      )
      addTrackingArea(area)
   }

   override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
   override func mouseExited(with event: NSEvent) { onMouseExited?() }
}

// MARK: - Notch controller

/// A borderless NSPanel that lives in the camera housing and fluidly expands
/// into a usage card — the Dynamic-Island-style "notch app" experience.
///
/// Dismissal is cursor-driven: the card collapses as soon as the cursor leaves
/// it (tracking area + polling fallback) or when you click anywhere outside.
@MainActor
final class NotchController {
   static let shared = NotchController()

   private let panel: NSPanel
   private let hostingView: NSHostingView<NotchContentView>
   private let effectView = NotchBackgroundView()

   private var collapsedFrame: NSRect = .zero
   private var expandedFrame: NSRect = .zero
   private(set) var isExpanded = false

   private var outsideSince: Date?
   private var pendingCollapseTask: Task<Void, Never>?
   private var hoverTimer: Timer?
   private var clickMonitor: Any?
   private var keyMonitor: Any?
   private var isPreviewing = false

   private let collapseGrace: TimeInterval = 0.4

   private init() {
      panel = NSPanel(
         contentRect: .zero,
         styleMask: [.borderless, .nonactivatingPanel],
         backing: .buffered,
         defer: false
      )
      panel.level = .statusBar
      panel.collectionBehavior = [
         .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
      ]
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.isMovable = false
      panel.hidesOnDeactivate = false
      panel.worksWhenModal = true
      // NOTE: must NOT set isFloatingPanel — it overrides `level` back to
      // .floating, which drops the panel below the menu bar and makes the
      // widget render *under* the notch instead of in it.
      panel.animationBehavior = .none

      effectView.wantsLayer = true
      // No layer corner-radius / clipping here: the SwiftUI card draws its own
      // shape (square top corners, rounded bottom), so clipping to a uniform
      // radius would round the top corners that must stay flush with the notch.

      let content = NotchContentView(model: AppModel.shared)
      hostingView = NSHostingView(rootView: content)
      hostingView.translatesAutoresizingMaskIntoConstraints = false

      effectView.addSubview(hostingView)
      NSLayoutConstraint.activate([
         hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
         hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
         hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
         hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
      ])
      panel.contentView = effectView

      // Wire up cursor tracking now that all stored properties are initialized.
      effectView.onMouseEntered = { [weak self] in
         Task { @MainActor in self?.cancelPendingCollapse() }
      }
      effectView.onMouseExited = { [weak self] in
         Task { @MainActor in self?.scheduleCollapse() }
      }

      // Polling fallback for hover-expand and leaving-the-card detection.
      let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
         Task { @MainActor in self?.tick() }
      }
      timer.tolerance = 0.05
      RunLoop.main.add(timer, forMode: .common)
      hoverTimer = timer

      // Click anywhere outside the card collapses it.
      clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
         [weak self] event in
         Task { @MainActor in self?.handleOutsideClick(event) }
      }
      // Esc collapses the card when the app is active.
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
         if event.keyCode == 53 {  // esc
            Task { @MainActor in self?.collapse() }
            return nil
         }
         return event
      }

      NotificationCenter.default.addObserver(
         self,
         selector: #selector(screenParametersChanged),
         name: NSApplication.didChangeScreenParametersNotification,
         object: nil
      )
   }

   // MARK: - State

   var isAvailable: Bool {
      guard AppModel.shared.config.settings.notchEnabled else { return false }
      // Works on non-notch displays too (pill at the top center), but is really
      // at home under a camera housing.
      return true
   }

   func update() {
      guard isAvailable else {
         panel.orderOut(nil)
         return
      }
      refreshFrames()
      if !panel.isVisible {
         // Ordering-in during launch: `isVisible` can still be false briefly
         // after orderFrontRegardless, so never stomp an expanded state back
         // to the collapsed frame.
         let target = isExpanded ? expandedFrame : collapsedFrame
         panel.setFrame(target, display: false)
         panel.orderFrontRegardless()
         if isExpanded {
            setExpandedAppearance()
         } else {
            setCollapsedAppearance()
         }
      } else if isExpanded {
         panel.setFrame(expandedFrame, display: true)
      } else {
         panel.setFrame(collapsedFrame, display: true)
         setCollapsedAppearance()
      }
   }

   func toggle() {
      isExpanded ? collapse() : expand()
   }

   func expand() {
      guard isAvailable else { return }
      guard !isExpanded else { return }  // never re-trigger the animation
      isExpanded = true
      outsideSince = nil
      cancelPendingCollapse()
      refreshFrames()
      setExpandedAppearance()
      animate(to: expandedFrame)
      AppModel.shared.notchStateDidChange()
   }

   func collapse() {
      guard isExpanded || panel.isVisible else { return }
      isExpanded = false
      outsideSince = nil
      cancelPendingCollapse()
      refreshFrames()
      setCollapsedAppearance()
      animate(to: collapsedFrame)
      AppModel.shared.notchStateDidChange()
   }

   /// Temporarily show the expanded card (used by the settings "Preview notch"
   /// button). Auto-collapse is suppressed so the card stays up while you look.
   func preview() {
      guard isAvailable else { return }
      isPreviewing = true
      expand()
      Task { [weak self] in
         try? await Task.sleep(for: .seconds(2.5))
         guard let self else { return }
         self.isPreviewing = false
         self.collapse()
      }
   }

   // MARK: - Frames

   private func refreshFrames() {
      guard let screen = NSScreen.main else { return }
      let height = max(screen.safeAreaInsets.top, 24)
      let width = CGFloat(AppModel.shared.config.settings.notchWidth)
      let top = screen.frame.maxY

      collapsedFrame = NSRect(
         x: screen.frame.midX - width / 2,
         y: top - height,
         width: width,
         height: height
      )

      // Landscape card: wide and short, like real notch widgets.
      let expandedWidth: CGFloat = 600
      let expandedHeight: CGFloat = 300
      expandedFrame = NSRect(
         x: screen.frame.midX - expandedWidth / 2,
         y: top - expandedHeight,
         width: expandedWidth,
         height: expandedHeight
      )
   }

   private func setCollapsedAppearance() {
      // Shadow lives in SwiftUI (downward-only), so the window never casts a
      // top-side shadow that would break the blend with the notch.
      panel.hasShadow = false
   }

   private func setExpandedAppearance() {
      panel.hasShadow = false
   }

   private func animate(to frame: NSRect) {
      // Both frames share the same top edge and center-x, so the card grows
      // downward and outward from the notch — like the housing extending.
      // This is the single source of motion: corner radius is set instantly
      // and SwiftUI has no transition, so there is exactly one animation.
      NSAnimationContext.runAnimationGroup { context in
         context.duration = 0.42
         // Smooth ease — no overshoot. An overshooting curve reads as two
         // separate motions (fast sweep, then settle back).
         context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
         context.allowsImplicitAnimation = true
         panel.animator().setFrame(frame, display: true)
      }
   }

   // MARK: - Dismissal / hover

   private func tick() {
      guard isAvailable, panel.isVisible else { return }
      let mouse = NSEvent.mouseLocation

      if !isExpanded {
         let hover = AppModel.shared.config.settings.autoExpandNotchOnHover
         if hover, collapsedFrame.insetBy(dx: -12, dy: -12).contains(mouse) {
            expand()
         }
         return
      }

      let grace = expandedFrame.insetBy(dx: -24, dy: -12)
      if grace.contains(mouse) {
         outsideSince = nil
      } else if !isPreviewing {
         if outsideSince == nil { outsideSince = Date() }
         if let since = outsideSince, Date().timeIntervalSince(since) > 0.55 {
            collapse()
         }
      }
   }

   private func handleOutsideClick(_ event: NSEvent) {
      guard isExpanded, !isPreviewing else { return }
      let location = event.locationInWindow  // screen coords for global monitors
      let frame = expandedFrame.insetBy(dx: -8, dy: -8)
      if !frame.contains(location) {
         collapse()
      }
   }

   private func scheduleCollapse() {
      guard isExpanded, !isPreviewing else { return }
      // A mouseExited can fire spuriously while the panel is resizing under the
      // cursor (tracking areas are recreated during layout). If the cursor is
      // still over the notch, ignore it — otherwise the card collapses and
      // immediately re-expands, which reads as a double animation.
      let mouse = NSEvent.mouseLocation
      if collapsedFrame.insetBy(dx: -12, dy: -12).contains(mouse) { return }

      pendingCollapseTask?.cancel()
      pendingCollapseTask = Task { [weak self] in
         try? await Task.sleep(for: .seconds(self?.collapseGrace ?? 0.4))
         guard let self, !Task.isCancelled else { return }
         self.collapse()
      }
   }

   private func cancelPendingCollapse() {
      pendingCollapseTask?.cancel()
      pendingCollapseTask = nil
   }

   @objc private func screenParametersChanged() {
      refreshFrames()
      if isExpanded {
         panel.setFrame(expandedFrame, display: true)
      } else {
         panel.setFrame(collapsedFrame, display: true)
      }
   }
}

// MARK: - Notch content

struct NotchContentView: View {
   @ObservedObject private var model: AppModel

   init(model: AppModel) {
      self.model = model
   }

   var body: some View {
      GeometryReader { geo in
         ZStack(alignment: .top) {
            if model.config.settings.notchEnabled {
               if model.isNotchExpanded {
                  expandedCard
               } else {
                  collapsedPill
               }
            }
         }
         .frame(width: geo.size.width, height: geo.size.height)
         .ignoresSafeArea()
      }
      // No SwiftUI transition here: the panel frame animation (single, driven
      // by NSAnimationContext) handles all motion. A second SwiftUI spring
      // would double-animate the card.
   }

   private var collapsedPill: some View {
      ZStack {
         // Capsule: corner radius = half the strip height, so the pill looks
         // like the camera housing's own rounded shape, not a square block.
         Capsule()
            .fill(Color.black)
            .overlay(
               Capsule()
                  .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
         if let snapshot = model.activeSnapshot {
            MiniGauge(
               progress: snapshot.session.fraction, level: snapshot.session.statusLevel, size: 30)
         } else {
            Image(systemName: "sparkles")
               .font(.system(size: 15, weight: .semibold))
               .foregroundStyle(Assets.accent)
         }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .onTapGesture { NotchController.shared.toggle() }
   }

   private var expandedCard: some View {
      cardBody
         .padding(.horizontal, 18)
         .padding(.top, topInset)
         .padding(.bottom, 16)
         .frame(maxWidth: .infinity, maxHeight: .infinity)
         .background(cardBackground)
         .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 14)
         .contentShape(Rectangle())
   }

   /// Height of the menu-bar / camera-housing strip the card must cover.
   private var topInset: CGFloat {
      max(NSScreen.main?.safeAreaInsets.top ?? 0, 37) + 8
   }

   /// Solid black card with uniform rounded corners (like BoringNotch / the
   /// Dynamic Island): flush against the screen top so it visually flows out
   /// of the camera housing. The downward-only shadow comes from `.shadow`.
   private var cardBackground: some View {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
         .fill(Color.black.opacity(0.96))
         .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
               .stroke(Color.white.opacity(0.07), lineWidth: 1)
         )
   }

   private var cardBody: some View {
      VStack(spacing: 12) {
         header
         if model.accounts.isEmpty {
            Spacer()
            VStack(spacing: 10) {
               Image(systemName: "person.crop.circle.badge.plus")
                  .font(.system(size: 28))
                  .foregroundStyle(Assets.accent)
               Text("Not signed in")
                  .font(.system(size: 15, weight: .semibold))
               Button("Sign in with Claude") {
                  model.startLogin()
               }
               .buttonStyle(.borderedProminent)
               .tint(Assets.accent)
            }
            Spacer()
         } else {
            // Landscape: both gauges side by side, trend below.
            HStack(spacing: 12) {
               sessionCard
               weeklyCard
            }
            historyChart
            footer
         }
      }
      .foregroundStyle(.primary)
   }

   private var header: some View {
      HStack(spacing: 8) {
         Image(systemName: "sparkles")
            .foregroundStyle(Assets.accent)
         Text("Claudophobia")
            .font(.system(size: 13, weight: .bold))
            .lineLimit(1)
         Spacer(minLength: 8)
         accountMenu
      }
   }

   private var accountMenu: some View {
      Menu {
         ForEach(model.accounts) { account in
            Button {
               model.setActive(id: account.id)
            } label: {
               if model.activeAccount?.id == account.id {
                  Label(account.name, systemImage: "checkmark")
               } else {
                  Text(account.name)
               }
            }
         }
      } label: {
         Text(model.activeAccount?.name ?? "Account")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 280)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
   }

   private var sessionCard: some View {
      NotchUsageCard(
         title: "Session · 5h",
         limit: model.activeSnapshot?.session,
         accent: Assets.sessionAccent
      )
   }

   private var weeklyCard: some View {
      NotchUsageCard(
         title: "Weekly · 7d",
         limit: model.activeSnapshot?.weekly,
         accent: Assets.weeklyAccent
      )
   }

   private var historyChart: some View {
      VStack(alignment: .leading, spacing: 4) {
         Text("Trend")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
         if model.activeHistory.isEmpty {
            Text("No history yet — usage appears after a few refreshes.")
               .font(.system(size: 10))
               .foregroundStyle(.tertiary)
               .frame(maxWidth: .infinity, alignment: .leading)
               .padding(.vertical, 8)
         } else {
            UsageSparkline(samples: model.activeHistory)
               .frame(height: 42)
         }
      }
   }

   private var footer: some View {
      HStack {
         if let last = model.lastRefresh {
            Text(Self.relativeTime(last.timeIntervalSinceNow))
               .font(.system(size: 10))
               .foregroundStyle(.tertiary)
         }
         Spacer()
         if model.isRefreshing {
            ProgressView()
               .controlSize(.small)
         } else {
            Button {
               Task { await model.refreshAll() }
            } label: {
               Image(systemName: "arrow.clockwise")
                  .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
         }
         Button {
            NotchController.shared.collapse()
            if let url = URL(string: "https://claude.ai/usage") {
               NSWorkspace.shared.open(url)
            }
         } label: {
            Image(systemName: "arrow.up.right.square")
               .font(.system(size: 11))
         }
         .buttonStyle(.plain)
         .foregroundStyle(.secondary)
      }
   }

   private static func relativeTime(_ interval: TimeInterval) -> String {
      "Updated " + RelativeDateTimeFormatter().localizedString(fromTimeInterval: interval)
   }
}

/// Compact usage row used inside the notch card.
struct NotchUsageCard: View {
   let title: String
   let limit: UsageLimit?
   let accent: Color

   var body: some View {
      HStack(spacing: 12) {
         ZStack {
            GaugeRing(progress: limit?.fraction ?? 0, color: accent, lineWidth: 7)
               .frame(width: 44, height: 44)
            Text("\(Int((limit?.utilization ?? 0).rounded()))%")
               .font(.system(size: 11, weight: .bold, design: .rounded))
         }
         VStack(alignment: .leading, spacing: 2) {
            Text(title)
               .font(.system(size: 11, weight: .semibold))
               .foregroundStyle(.secondary)
            Text("\(Int((limit?.utilization ?? 0).rounded()))% used")
               .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(limit?.resetDescription ?? "—")
               .font(.system(size: 10))
               .foregroundStyle(.tertiary)
         }
         Spacer()
         if let level = limit?.statusLevel {
            Circle()
               .fill(level.color)
               .frame(width: 8, height: 8)
         }
      }
      .padding(12)
      .background(
         RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.06))
      )
   }
}

// MARK: - Expansion state bridge

extension AppModel {
   /// Published via objectWillChange ticks so the notch view can animate.
   var isNotchExpanded: Bool { NotchController.shared.isExpanded }
}
