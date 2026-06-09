//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

private let junchatTencentMapSDKKey = Bundle.main.object(forInfoDictionaryKey: "TencentMapSDKKey") as? String
private let junchatForceStableMap = true

struct LocationSharingScreen: View {
    @Bindable var context: LocationSharingScreenViewModel.Context
    
    var body: some View {
        switch context.viewState.interactionMode {
        case .picker:
            mainContent
                .sheet(isPresented: .constant(true)) {
                    LocationPickerSheet(context: context)
                        .alert(item: $context.alertInfo)
                }
        case .viewStatic:
            mainContent
                .sheet(isPresented: .constant(true)) {
                    StaticLocationSheet(context: context)
                        .alert(item: $context.alertInfo)
                }
        case .viewLive:
            mainContent
                .sheet(isPresented: .constant(true)) {
                    LiveLocationSheet(context: context)
                        .alert(item: $context.alertInfo)
                }
        }
    }
    
    // MARK: - Private
    
    private var mainContent: some View {
        mapView
            .ignoresSafeArea(edges: .bottom)
            .track(screen: context.viewState.interactionMode == .picker ? .LocationSend : .LocationView)
            .navigationTitle(L10n.screenViewLocationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
    }
    
    private var mapView: some View {
        ZStack(alignment: .center) {
            switch JunchatMapProvider.from(sdkKey: junchatTencentMapSDKKey, forceStableMap: junchatForceStableMap) {
            case .stable, .tencent:
                JunchatMapKitMapView(options: mapOptions,
                                     mediaProvider: context.mediaProvider,
                                     showsUserLocationMode: $context.showsUserLocationMode,
                                     mapCenterCoordinate: $context.mapCenterLocation,
                                     hasLoadedUserLocation: $context.hasLoadedUserLocation,
                                     isLocationAuthorized: $context.isLocationAuthorized,
                                     geolocationUncertainty: $context.geolocationUncertainty) {
                    context.send(viewAction: .userDidPan)
                }
                .ignoresSafeArea(edges: mapSafeAreaEdges)
            }
            
            if let markerKind = context.viewState.pickerMarkerKind {
                LocationMarkerView(kind: markerKind, mediaProvider: context.mediaProvider)
            }
        }
        .overlay(alignment: .topTrailing) {
            centerToUserLocationButton
        }
    }
    
    private var mapSafeAreaEdges: Edge.Set {
        context.viewState.interactionMode == .picker ? .horizontal : [.horizontal, .bottom]
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ToolbarButton(role: .close) {
                context.send(viewAction: .close)
            }
        }
    }
    
    private var mapOptions: MapLibreMapView.Options {
        .init(zoomLevel: context.viewState.zoomLevel,
              initialZoomLevel: context.viewState.initialZoomLevel,
              mapCenter: context.viewState.initialMapCenter,
              annotations: context.viewState.annotations)
    }
    
    @ViewBuilder
    private var centerToUseIcon: some View {
        if context.viewState.isLocationLoading {
            ProgressView()
                .tint(.compound.iconPrimary)
                .padding(13)
        } else {
            CompoundIcon(context.viewState.isSharingUserLocation ? \.locationNavigatorCentred : \.locationNavigator)
                .foregroundStyle(.compound.iconPrimary)
                .padding(13)
        }
    }
    
    private var centerToUserLocationButton: some View {
        Button {
            context.send(viewAction: .centerToUser)
        } label: {
            if #available(iOS 26.0, *) {
                centerToUseIcon
                    .glassEffect(.regular.interactive(), in: Circle())
                    .tint(.compound.bgCanvasDefault)
            } else {
                centerToUseIcon
                    .background(.compound.bgCanvasDefault, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .disabled(context.viewState.isLocationLoading)
        .dynamicTypeSize(.large)
        .padding(13)
    }
}

private struct JunchatLocationMapFallbackView: View {
    let interactionMode: LocationSharingInteractionMode
    
    var body: some View {
        VStack(spacing: 12) {
            CompoundIcon(\.locationPin, size: .medium, relativeTo: .compound.headingXL)
                .foregroundStyle(.compound.iconAccentPrimary)
            
            Text("地图预览暂不可用")
                .font(.compound.bodyLGSemibold)
                .foregroundStyle(.compound.textPrimary)
            
            Text(message)
                .font(.compound.bodyMD)
                .foregroundStyle(.compound.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.compound.bgCanvasDefault)
    }
    
    private var message: String {
        switch interactionMode {
        case .picker:
            "仍可发送当前位置或共享实时位置。为提升国内环境稳定性，已暂时关闭地图预览。"
        case .viewStatic:
            "位置消息已保留，地图预览暂时关闭以避免国内环境崩溃。"
        case .viewLive:
            "实时位置共享仍可使用，地图预览暂时关闭以避免国内环境崩溃。"
        }
    }
}

// MARK: - Previews

struct LocationSharingScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = LocationSharingScreenViewModel.mock(type: .staticSenderLocation)
        
    static let pinViewModel = LocationSharingScreenViewModel.mock(type: .staticPinLocation)
    
    static let pickerViewModel = LocationSharingScreenViewModel.mock(type: .picker)
    
    static let liveLocationViewModel = LocationSharingScreenViewModel.mock(type: .viewLive)
    
    static var previews: some View {
        ElementNavigationStack {
            LocationSharingScreen(context: pickerViewModel.context)
        }
        .previewDisplayName("Picker")
        
        ElementNavigationStack {
            LocationSharingScreen(context: viewModel.context)
        }
        .previewDisplayName("User Static Location")
        
        ElementNavigationStack {
            LocationSharingScreen(context: pinViewModel.context)
        }
        .previewDisplayName("Pin Static Location")
        
        ElementNavigationStack {
            LocationSharingScreen(context: liveLocationViewModel.context)
        }
        .previewDisplayName("Live Location")
    }
}
