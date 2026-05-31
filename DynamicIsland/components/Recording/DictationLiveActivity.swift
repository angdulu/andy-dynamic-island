/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import SwiftUI
import Defaults

struct DictationLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var dictationManager = DictationManager.shared
    @State private var isExpanded = false
    
    var body: some View {
        let sideSize = max(0, vm.effectiveClosedNotchHeight - 12)
        
        HStack(spacing: 0) {
            // Left Side - Empty for symmetry
            Color.clear
                .frame(width: isExpanded ? sideSize : 0, height: sideSize)
            
            // Center - Black notch area
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width)
            
            // Right Side - Status Icons (Mic for Recording, Andy for Transcribing)
            Color.clear
                .background {
                    if isExpanded {
                        HStack {
                            if dictationManager.isRecording {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.orange)
                                    .frame(width: sideSize, height: sideSize, alignment: .center)
                            } else if dictationManager.isTranscribing {
                                ClosedAndyWing(size: sideSize)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
                .frame(width: isExpanded ? sideSize : 0, height: sideSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .onAppear {
            withAnimation(.smooth(duration: 0.4)) {
                isExpanded = true
            }
        }
        .onChange(of: dictationManager.isRecording) { _, newValue in
            updateExpansionState()
        }
        .onChange(of: dictationManager.isTranscribing) { _, newValue in
            updateExpansionState()
        }
    }
    
    private func updateExpansionState() {
        let isActive = dictationManager.isRecording || dictationManager.isTranscribing
        withAnimation(.smooth(duration: 0.4)) {
            isExpanded = isActive
        }
    }
}
