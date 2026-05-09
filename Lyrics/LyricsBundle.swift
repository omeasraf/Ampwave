//
//  LyricsBundle.swift
//  Lyrics
//
//  Created by Ome Asraf on 4/11/26.
//

internal import SwiftUI
import WidgetKit

@main
struct LyricsBundle: WidgetBundle {
  var body: some Widget {
    Lyrics()
    NowPlayingWidget()
  }
}
