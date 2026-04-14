//
//  AppIntent.swift
//  Lyrics
//
//  Created by Ome Asraf on 4/11/26.
//

import WidgetKit
import AppIntents

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Configuration" }
    static var description: IntentDescription { "Coming soon" }

    // An example configurable parameter.
//    @Parameter(title: "Favorite Emoji", default: "😃")
//    var favoriteEmoji: String
}
