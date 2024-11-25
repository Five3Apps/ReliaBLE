//
//  ContentView.swift
//  ReliaBLE Demo
//
//  Created by Justin Bergen on 11/18/24.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            PeripheralView()
                .tabItem {
                    Label("Peripheral", systemImage: "dot.radiowaves.left.and.right")
                }
            
            CentralView()
                .tabItem {
                    Label("Central", systemImage: "antenna.radiowaves.left.and.right")
                }
        }
    }
}

#Preview {
    ContentView()
}
