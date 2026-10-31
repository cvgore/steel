//
//  ChartsBarChartViewRepresentable.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 20.06.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import DGCharts

struct ChartsBarChartViewRepresentable : UIViewRepresentable {
    var chartData: ChartData
    var xAxisValueFormatter: AxisValueFormatter
    var yAxisValueFormatter: AxisValueFormatter
    var preCustomization: ((DGCharts.BarChartView, ChartData) -> ())?
    var postCustomization: ((DGCharts.BarChartView) -> ())?

    func makeUIView(context: UIViewRepresentableContext<ChartsBarChartViewRepresentable>) -> StyledBarChartView {
        StyledBarChartView()
    }
    
    func updateUIView(_ uiView: StyledBarChartView, context: UIViewRepresentableContext<ChartsBarChartViewRepresentable>) {
        uiView.xAxis.valueFormatter = xAxisValueFormatter
        uiView.leftAxis.valueFormatter = yAxisValueFormatter
        preCustomization?(uiView, chartData)
        uiView.data = chartData
        uiView.fitScreen()
        postCustomization?(uiView)
    }
}
