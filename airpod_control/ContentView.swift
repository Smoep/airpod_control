//
//  ContentView.swift
//  airpod_control
//
//  Created by Jos on 25/4/26.
//

import SwiftUI

struct ContentView: View {
    @Bindable var store: LiveSensorStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TabView {
            OverviewView(store: store)
                .tabItem {
                    Label("Motion", systemImage: "waveform.path.ecg")
                }

            GestureControlView(store: store)
                .tabItem {
                    Label("Gestures", systemImage: "hand.draw")
                }

            GestureSettingsView(store: store)
            .tabItem {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        }
        .frame(minWidth: 980, minHeight: 720)
        .background(
            LinearGradient(
                colors: backgroundGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear {
            store.recenterGesturePreviewToCurrentHead()
        }
    }

    private var backgroundGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.08, green: 0.10, blue: 0.14),
                Color(red: 0.11, green: 0.16, blue: 0.22)
            ]
        }

        return [
            Color(red: 0.92, green: 0.95, blue: 0.98),
            Color(red: 0.84, green: 0.90, blue: 0.96)
        ]
    }
}

#Preview {
    ContentView(store: LiveSensorStore())
}
