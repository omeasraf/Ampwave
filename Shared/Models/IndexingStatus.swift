//
//  IndexingStatus.swift
//  Ampwave
//
//  Indexing status enum for library scanning.
//

import Foundation

enum IndexingStatus: Equatable {
  case idle
  case indexing(String)
  case fetchingMetadata(Int)
  case complete
}
