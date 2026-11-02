//
//  RPE.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 22.08.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation

public enum RPE {
    public static let allowedValues = WorkoutEditingRules.allowedRPE
    
    public static func title(_ rpe: Double) -> String? {
        switch rpe {
        case 7:
            return L10n.string("You could do 3 more repetitions.")
        case 7.5:
            return L10n.string("You could do 2-3 more repetitions.")
        case 8:
            return L10n.string("You could do 2 more repetitions.")
        case 8.5:
            return L10n.string("You could do 1-2 more repetitions.")
        case 9:
            return L10n.string("You could do 1 more repetitions.")
        case 9.5:
            return L10n.string("You couldn't do any more repetitions, but possibly you could've increased the weight.")
        case 10:
            return L10n.string("You couldn't do any more repetitions.")
        default:
            return nil
        }
    }
}
