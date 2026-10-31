//
//  IntentWeight+Measurement.swift
//  IronIntents
//
//  Created by Karim Abou Zeid on 12.12.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation

// This class is needed, because there is a bug in Siri where it crashes if we just use Measurement<UnitMass> with .pounds
extension IntentWeight {
    convenience init(measurement: Measurement<UnitMass>, weightUnit: WeightUnit) {
        let measurement = measurement.converted(to: weightUnit.unit)
        let formatter = weightUnit.formatter
        formatter.locale = L10n.locale
        formatter.numberFormatter.locale = L10n.locale
        formatter.numberFormatter.maximumFractionDigits = 1
        let display = formatter.string(from: measurement)
        self.init(identifier: nil, display: display, pronunciationHint: display.replacingOccurrences(of: "kg", with: L10n.string("kilograms")).replacingOccurrences(of: "lb", with: L10n.string("pounds")))
        self.value = measurement.value as NSNumber
        self.unit = weightUnit.unit.symbol
    }
}
