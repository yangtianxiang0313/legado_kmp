// Geometry adapted from ColorPickerView.java, com.jaredrummler:colorpicker:1.1.0.
// Copyright (C) 2017 Jared Rummler
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import UIKit

struct ReaderColorCustomPickerGeometry {
    // cpv_dialog_color_picker.xml and cpv_ColorPickerViewStyle in the 1.1.0 AAR.
    static let padding: CGFloat = 16
    static let hueWidth: CGFloat = 30
    static let spacing: CGFloat = 10
    static let preferredHeight: CGFloat = 315

    private static let minimumPlaneSide: CGFloat = 12
    private static let minimumWidth = padding * 2 + hueWidth + spacing + minimumPlaneSide
    private static let minimumHeight = padding * 2 + minimumPlaneSide

    let saturationValueFrame: CGRect
    let hueFrame: CGRect
    let metricScale: CGFloat
    let borderWidth: CGFloat

    var trackerOutset: CGFloat { 6 * metricScale }

    init(bounds: CGRect, displayScale: CGFloat) {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
            bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0
        else {
            saturationValueFrame = .zero
            hueFrame = .zero
            metricScale = 0
            borderWidth = 0
            return
        }

        // Keep source metrics until the available size cannot hold even a small SV plane.
        let scale = min(1, min(bounds.width / Self.minimumWidth, bounds.height / Self.minimumHeight))
        let drawingRect = bounds.insetBy(dx: Self.padding * scale, dy: Self.padding * scale)
        metricScale = scale
        borderWidth = scale / (displayScale.isFinite ? max(displayScale, 1) : 1)
        saturationValueFrame = CGRect(
            x: drawingRect.minX, y: drawingRect.minY,
            width: drawingRect.width - (Self.hueWidth + Self.spacing) * scale,
            height: drawingRect.height)
        hueFrame = CGRect(
            x: drawingRect.maxX - Self.hueWidth * scale, y: drawingRect.minY,
            width: Self.hueWidth * scale, height: drawingRect.height)
    }

    static var preferredSize: CGSize {
        CGSize(width: preferredHeight + hueWidth + spacing, height: preferredHeight)
    }

    static func sizeThatFits(_ proposal: CGSize) -> CGSize {
        var width = proposal.width.isFinite && proposal.width > 0 ? proposal.width : preferredSize.width
        var height = Self.height(forWidth: width)
        if proposal.height.isFinite, proposal.height > 0, height > proposal.height {
            height = proposal.height
            width = min(width, Self.width(forHeight: height))
        }
        return CGSize(width: width, height: height)
    }

    private static func height(forWidth width: CGFloat) -> CGFloat {
        width >= minimumWidth ? width - hueWidth - spacing : width * minimumHeight / minimumWidth
    }

    private static func width(forHeight height: CGFloat) -> CGFloat {
        height >= minimumHeight ? height + hueWidth + spacing : height * minimumWidth / minimumHeight
    }

    static func unit(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint? {
        guard !rect.isEmpty, point.x.isFinite, point.y.isFinite else { return nil }
        return CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }
}
