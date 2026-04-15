//
//  AppIntent.swift
//  Lyrics
//
//  Created by Ome Asraf on 4/11/26.
//

import WidgetKit
import AppIntents

public struct ConfigurationAppIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource { "Configuration" }
    public static var description: IntentDescription { "Configure your lyrics widget." }

    public init() {}
}
