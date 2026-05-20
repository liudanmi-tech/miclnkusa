//
//  ImageCropView.swift
//  WorkSurvivalGuide
//
//  照片裁剪视图 - 选照片后让用户移动缩放裁剪

import SwiftUI

struct ImageCropView: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    @State private var storedCropDiam: CGFloat = 0
    @State private var storedBaseW: CGFloat = 0
    @State private var storedBaseH: CGFloat = 0
    @State private var storedGeoSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .top) {

            // ── 裁剪交互区：全屏填充 ────────────────────────────────────────
            GeometryReader { geo in
                let cd  = min(geo.size.width, geo.size.height) * 0.82
                let asp = image.size.width / image.size.height
                let bW: CGFloat = asp >= 1 ? cd * asp : cd
                let bH: CGFloat = asp >= 1 ? cd       : cd / asp

                ZStack {
                    Color.black

                    Image(uiImage: image)
                        .resizable()
                        .frame(width: bW * scale, height: bH * scale)
                        .offset(x: offset.width, y: offset.height)
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { v in
                                        let s = max(1.0, lastScale * v)
                                        scale  = s
                                        offset = clamped(offset, s: s, bW: bW, bH: bH, cd: cd)
                                    }
                                    .onEnded { _ in
                                        lastScale  = scale
                                        lastOffset = offset
                                    },
                                DragGesture()
                                    .onChanged { v in
                                        let p = CGSize(
                                            width:  lastOffset.width  + v.translation.width,
                                            height: lastOffset.height + v.translation.height
                                        )
                                        offset = clamped(p, s: scale, bW: bW, bH: bH, cd: cd)
                                    }
                                    .onEnded { _ in
                                        lastOffset = offset
                                    }
                            )
                        )

                    // Dim layer with circle hole
                    CropFrameShape(cropDiameter: cd)
                        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)

                    // Guide ring
                    Circle()
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                        .frame(width: cd, height: cd)
                        .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .onAppear {
                    store(cd: cd, bW: bW, bH: bH, size: geo.size)
                }
                .onChange(of: geo.size) { sz in
                    let newCd  = min(sz.width, sz.height) * 0.82
                    let newAsp = image.size.width / image.size.height
                    store(cd:  newCd,
                          bW:  newAsp >= 1 ? newCd * newAsp : newCd,
                          bH:  newAsp >= 1 ? newCd           : newCd / newAsp,
                          size: sz)
                }
            }
            .ignoresSafeArea()  // 裁剪区填满全屏

            // ── 顶部按钮栏：ZStack 内不使用 ignoresSafeArea，自动停在状态栏下方 ──
            HStack(spacing: 0) {
                Button(action: { onCancel() }) {
                    Text("Cancel")
                        .foregroundColor(.white)
                        .font(.system(size: 17))
                }
                .frame(minWidth: 80, alignment: .leading)

                Spacer()

                Text("Move and Scale")
                    .foregroundColor(.white)
                    .font(.system(size: 17, weight: .semibold))

                Spacer()

                Button(action: { onCrop(renderCrop()) }) {
                    Text("Done")
                        .foregroundColor(Color(red: 0.984, green: 0.749, blue: 0.141))
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(minWidth: 80, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 80)
            .padding(.bottom, 18)
            .background(Color.black)
        }
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - Helpers

    private func store(cd: CGFloat, bW: CGFloat, bH: CGFloat, size: CGSize) {
        storedCropDiam = cd
        storedBaseW    = bW
        storedBaseH    = bH
        storedGeoSize  = size
    }

    private func clamped(_ p: CGSize, s: CGFloat,
                          bW: CGFloat, bH: CGFloat, cd: CGFloat) -> CGSize {
        let maxX = max(0, (bW * s) / 2 - cd / 2)
        let maxY = max(0, (bH * s) / 2 - cd / 2)
        return CGSize(
            width:  p.width .clamped(to: -maxX...maxX),
            height: p.height.clamped(to: -maxY...maxY)
        )
    }

    private func renderCrop() -> UIImage {
        let cd   = storedCropDiam
        let size = storedGeoSize
        let imgW = storedBaseW * scale
        let imgH = storedBaseH * scale
        let drawX = (size.width  / 2 + offset.width  - imgW / 2) - (size.width  - cd) / 2
        let drawY = (size.height / 2 + offset.height - imgH / 2) - (size.height - cd) / 2

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: cd, height: cd))
        return renderer.image { _ in
            image.draw(in: CGRect(x: drawX, y: drawY, width: imgW, height: imgH))
        }
    }
}

// MARK: - Dim shape: full rect with circle hole (even-odd fill cuts the hole)

struct CropFrameShape: Shape {
    let cropDiameter: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addEllipse(in: CGRect(
            x: rect.midX - cropDiameter / 2,
            y: rect.midY - cropDiameter / 2,
            width: cropDiameter,
            height: cropDiameter
        ))
        return path
    }
}

// MARK: - Clamp helper

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
