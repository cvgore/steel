//
//  Quote.swift
//  Iron
//
//  Created by Karim Abou Zeid on 17.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation

struct Quote: Decodable {
    let text: String
    let person: String?
}

extension Quote {
    var displayText: String {
        L10n.string(text).enquoted + (person.map { " – \(L10n.string($0))" } ?? "")
    }
}
