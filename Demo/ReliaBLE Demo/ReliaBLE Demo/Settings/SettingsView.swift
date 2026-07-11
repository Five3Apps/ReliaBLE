//
//  SettingsView.swift
//  ReliaBLE Demo
//
//  Created by Justin Bergen on 3/8/24.
//
//  Copyright (c) 2025 Five3 Apps, LLC <justin@five3apps.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import SwiftUI

import ReliaBLE

struct SettingsView: View {
    @Environment(\.bleManager) private var reliaBLE
    @State private var isLoggingEnabled: Bool = false

    @AppStorage("reconnectPolicy.maxAttempts") private var maxAttempts = 5
    @AppStorage("reconnectPolicy.initialDelay") private var initialDelay = 1.0
    @AppStorage("reconnectPolicy.maxDelay") private var maxDelay = 30.0
    @AppStorage("reconnectPolicy.jitter") private var jitter = 0.2

    var body: some View {
        NavigationView {
            Form {
                Section("Logging") {
                    Toggle("Enable Logging", isOn: $isLoggingEnabled)
                }

                Section {
                    Stepper("Max Attempts: \(maxAttempts)", value: $maxAttempts, in: 1...20)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Initial Delay: \(String(format: "%.1f", initialDelay))s")
                        Slider(value: $initialDelay, in: 0.5...10, step: 0.5)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Max Delay: \(String(format: "%.0f", maxDelay))s")
                        Slider(value: $maxDelay, in: 5...120, step: 5)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Jitter: \(String(format: "%.2f", jitter))")
                        Slider(value: $jitter, in: 0...0.5, step: 0.05)
                    }

                    Text("Changes take effect on next app launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Reconnect Policy")
                }
            }
            .navigationTitle("Settings")
        }
        .onAppear {
            isLoggingEnabled = reliaBLE.loggingService.enabled
        }
        .onChange(of: isLoggingEnabled) { _, newValue in
            reliaBLE.loggingService.enabled = newValue
        }
    }
}

#Preview {
    SettingsView()
}
