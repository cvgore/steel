//
//  ChartsLineChartViewRepresentable.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 20.06.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import DGCharts

struct ChartsLineChartViewRepresentable : UIViewRepresentable {
    let chartData: ChartData
    let xAxisValueFormatter: AxisValueFormatter?
    let yAxisValueFormatter: AxisValueFormatter?
    let balloonValueFormatter: BalloonValueFormatter?
    var preCustomization: ((DGCharts.LineChartView, ChartData) -> ())?
    var postCustomization: ((DGCharts.LineChartView) -> ())?

    func makeUIView(context: UIViewRepresentableContext<ChartsLineChartViewRepresentable>) -> StyledLineChartView {
        StyledLineChartView()
    }
    
    func updateUIView(_ uiView: StyledLineChartView, context: UIViewRepresentableContext<ChartsLineChartViewRepresentable>) {
        uiView.xAxis.valueFormatter = xAxisValueFormatter
        uiView.leftAxis.valueFormatter = yAxisValueFormatter
        uiView.balloonMarker.valueFormatter = balloonValueFormatter
        preCustomization?(uiView, chartData)
        uiView.data = chartData
        uiView.fitScreen()
        postCustomization?(uiView)
    }
}
