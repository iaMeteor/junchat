//
// Copyright 2026 Junchat.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreLocation
import MapKit
import SwiftUI

protocol JunchatMapKitLocationManagerProtocol: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var location: CLLocation? { get }
    
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

extension CLLocationManager: JunchatMapKitLocationManagerProtocol { }

struct JunchatMapKitMapView: UIViewRepresentable {
    let options: MapLibreMapView.Options
    let mediaProvider: MediaProviderProtocol?

    @Binding var showsUserLocationMode: ShowUserLocationMode
    @Binding var mapCenterCoordinate: CLLocationCoordinate2D?
    @Binding var hasLoadedUserLocation: Bool
    @Binding var isLocationAuthorized: Bool?
    @Binding var geolocationUncertainty: CLLocationAccuracy?

    var userDidPan: (() -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.pointOfInterestFilter = .includingAll
        mapView.showsCompass = false
        mapView.showsScale = true
        mapView.showsTraffic = false
        context.coordinator.configureInitialRegion(on: mapView, options: options)
        context.coordinator.updateAnnotations(in: mapView, annotations: options.annotations, mediaProvider: mediaProvider)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        if let newCenter = mapCenterCoordinate,
           newCenter != context.coordinator.lastReportedCenter {
            context.coordinator.setCenter(newCenter, on: mapView, animated: true)
        }

        context.coordinator.updateAnnotations(in: mapView, annotations: options.annotations, mediaProvider: mediaProvider)
        context.coordinator.updateUserLocationMode(on: mapView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}

extension JunchatMapKitMapView {
    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        var parent: JunchatMapKitMapView
        var lastReportedCenter: CLLocationCoordinate2D?

        private let locationManager: JunchatMapKitLocationManagerProtocol
        private let locationFallbackDelay: TimeInterval
        private var cachedAuthorizationStatus: CLAuthorizationStatus
        private var isProgrammaticRegionChange = false
        private var hasCenteredOnUserLocation = false
        private var lastCenteredUserLocationCoordinate: CLLocationCoordinate2D?
        private var didRequestWhenInUseAuthorization = false
        private var isUpdatingLocation = false
        private var latestUserLocation: CLLocation?
        private var locationFallbackWorkItem: DispatchWorkItem?

        init(_ parent: JunchatMapKitMapView,
             locationManager: JunchatMapKitLocationManagerProtocol = CLLocationManager(),
             locationFallbackDelay: TimeInterval = 8) {
            self.parent = parent
            self.locationManager = locationManager
            self.locationFallbackDelay = locationFallbackDelay
            cachedAuthorizationStatus = locationManager.authorizationStatus
            super.init()
            locationManager.delegate = self
            updateAuthorizationStatus(cachedAuthorizationStatus)
        }

        func configureInitialRegion(on mapView: MKMapView, options: MapLibreMapView.Options) {
            let distance = mapDistance(for: options.annotations.isEmpty ? options.initialZoomLevel : options.zoomLevel)
            let region = MKCoordinateRegion(center: options.mapCenter, latitudinalMeters: distance, longitudinalMeters: distance)
            lastReportedCenter = options.mapCenter
            setRegion(region, on: mapView, animated: false)
        }

        func setCenter(_ coordinate: CLLocationCoordinate2D, on mapView: MKMapView, animated: Bool) {
            lastReportedCenter = coordinate
            isProgrammaticRegionChange = true
            mapView.setCenter(coordinate, animated: animated)
        }

        func updateAnnotations(in mapView: MKMapView,
                               annotations: [LocationAnnotation],
                               mediaProvider: MediaProviderProtocol?) {
            let existingAnnotations = mapView.annotations.compactMap { $0 as? JunchatMapKitAnnotation }
            let existingByID = Dictionary(uniqueKeysWithValues: existingAnnotations.map { ($0.id, $0) })
            let updatedByID = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, $0) })

            let existingIDs = Set(existingByID.keys)
            let updatedIDs = Set(updatedByID.keys)

            let removedAnnotations = existingIDs
                .subtracting(updatedIDs)
                .compactMap { existingByID[$0] }
            if removedAnnotations.isEmpty == false {
                mapView.removeAnnotations(removedAnnotations)
            }

            let addedAnnotations = updatedIDs
                .subtracting(existingIDs)
                .compactMap { updatedByID[$0] }
                .map(JunchatMapKitAnnotation.init)
            if addedAnnotations.isEmpty == false {
                mapView.addAnnotations(addedAnnotations)
            }

            let keptIDs = existingIDs.intersection(updatedIDs)
            for id in keptIDs {
                guard let existingAnnotation = existingByID[id],
                      let updatedAnnotation = updatedByID[id] else {
                    continue
                }
                existingAnnotation.coordinate = updatedAnnotation.coordinate
                existingAnnotation.kind = updatedAnnotation.kind
                if let annotationView = mapView.view(for: existingAnnotation) as? JunchatMapKitAnnotationView {
                    annotationView.updateContent(with: updatedAnnotation.kind, mediaProvider: mediaProvider)
                }
            }
        }

        func updateUserLocationMode(on mapView: MKMapView) {
            mapViewForLocationUpdate = mapView
            
            switch parent.showsUserLocationMode {
            case .hide:
                lastCenteredUserLocationCoordinate = nil
                if mapView.showsUserLocation {
                    mapView.showsUserLocation = false
                }
                if mapView.userTrackingMode != .none {
                    mapView.userTrackingMode = .none
                }
                if isUpdatingLocation {
                    locationManager.stopUpdatingLocation()
                    isUpdatingLocation = false
                }
            case .show, .showAndFollow:
                requestLocationAccessIfNeeded()
                guard isLocationAuthorized else { return }
                
                if !mapView.showsUserLocation {
                    mapView.showsUserLocation = true
                }
                if !isUpdatingLocation {
                    locationManager.startUpdatingLocation()
                    isUpdatingLocation = true
                }
                scheduleLocationFallbackIfNeeded()
                
                if parent.showsUserLocationMode == .showAndFollow {
                    if mapView.userTrackingMode != .follow {
                        mapView.userTrackingMode = .follow
                    }
                    centerOnUserLocationIfPossible(on: mapView)
                } else {
                    lastCenteredUserLocationCoordinate = nil
                    if mapView.userTrackingMode != .none {
                        mapView.userTrackingMode = .none
                    }
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? JunchatMapKitAnnotation else {
                return nil
            }

            let reuseIdentifier = "\(JunchatMapKitAnnotationView.self)"
            let annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? JunchatMapKitAnnotationView
                ?? JunchatMapKitAnnotationView(annotation: annotation, reuseIdentifier: reuseIdentifier)
            annotationView.annotation = annotation
            annotationView.updateContent(with: annotation.kind, mediaProvider: parent.mediaProvider)
            return annotationView
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if isProgrammaticRegionChange == false {
                parent.userDidPan?()
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.centerCoordinate
            lastReportedCenter = center
            isProgrammaticRegionChange = false
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.parent.mapCenterCoordinate != center else {
                    return
                }
                self.parent.mapCenterCoordinate = center
            }
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            cachedAuthorizationStatus = manager.authorizationStatus
            updateAuthorizationStatus(cachedAuthorizationStatus)
            updateUserLocationModeIfPossible()
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let location = locations.last else { return }
            cancelLocationFallback()
            latestUserLocation = location
            parent.hasLoadedUserLocation = true
            parent.geolocationUncertainty = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil

            if parent.showsUserLocationMode == .showAndFollow,
               let mapView = mapViewForLocationUpdate {
                centerOnUserLocationIfPossible(on: mapView)
            }
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            MXLog.error("Failed locating user with MapKit: \(error)")
            finishInitialLocationAttemptWithoutLocation()
        }

        private var isLocationAuthorized: Bool {
            switch cachedAuthorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                return true
            default:
                return false
            }
        }

        private weak var mapViewForLocationUpdate: MKMapView?

        private func setRegion(_ region: MKCoordinateRegion, on mapView: MKMapView, animated: Bool) {
            mapViewForLocationUpdate = mapView
            isProgrammaticRegionChange = true
            mapView.setRegion(region, animated: animated)
        }

        private func centerOnUserLocationIfPossible(on mapView: MKMapView) {
            guard let location = latestUserLocation else { return }
            let coordinate = location.coordinate
            guard lastCenteredUserLocationCoordinate != coordinate else { return }
            
            let distance = mapDistance(for: parent.options.zoomLevel)
            let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: distance, longitudinalMeters: distance)
            lastCenteredUserLocationCoordinate = coordinate
            lastReportedCenter = coordinate
            if parent.mapCenterCoordinate != coordinate {
                parent.mapCenterCoordinate = coordinate
            }
            setRegion(region, on: mapView, animated: hasCenteredOnUserLocation)
            hasCenteredOnUserLocation = true
        }

        private func requestLocationAccessIfNeeded() {
            guard cachedAuthorizationStatus == .notDetermined,
                  !didRequestWhenInUseAuthorization else {
                return
            }
            
            didRequestWhenInUseAuthorization = true
            locationManager.requestWhenInUseAuthorization()
        }
        
        private func scheduleLocationFallbackIfNeeded() {
            guard locationFallbackWorkItem == nil,
                  !parent.hasLoadedUserLocation,
                  locationFallbackDelay > 0 else {
                return
            }
            
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      !self.parent.hasLoadedUserLocation else {
                    return
                }
                MXLog.warning("Timed out waiting for the initial MapKit user location.")
                finishInitialLocationAttemptWithoutLocation()
            }
            locationFallbackWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + locationFallbackDelay, execute: workItem)
        }
        
        private func cancelLocationFallback() {
            locationFallbackWorkItem?.cancel()
            locationFallbackWorkItem = nil
        }
        
        private func finishInitialLocationAttemptWithoutLocation() {
            cancelLocationFallback()
            parent.hasLoadedUserLocation = true
            parent.geolocationUncertainty = nil
            if parent.showsUserLocationMode == .showAndFollow {
                parent.showsUserLocationMode = .show
            }
        }

        private func updateAuthorizationStatus(_ status: CLAuthorizationStatus) {
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                parent.isLocationAuthorized = true
            case .denied, .restricted:
                parent.isLocationAuthorized = false
            case .notDetermined:
                parent.isLocationAuthorized = nil
            @unknown default:
                break
            }
        }

        private func updateUserLocationModeIfPossible() {
            guard let mapView = mapViewForLocationUpdate else { return }
            updateUserLocationMode(on: mapView)
        }

        private func mapDistance(for zoomLevel: Double) -> CLLocationDistance {
            switch zoomLevel {
            case 15...:
                return 900
            case 10..<15:
                return 8_000
            case 6..<10:
                return 80_000
            default:
                return 8_000_000
            }
        }
    }
}

private final class JunchatMapKitAnnotation: NSObject, MKAnnotation {
    let id: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var kind: LocationMarkerKind

    init(annotation: LocationAnnotation) {
        id = annotation.id
        coordinate = annotation.coordinate
        kind = annotation.kind
        super.init()
    }
}

private final class JunchatMapKitAnnotationView: MKAnnotationView {
    private var hostingController: UIHostingController<AnyView>?

    func updateContent(with kind: LocationMarkerKind, mediaProvider: MediaProviderProtocol?) {
        let markerView = LocationMarkerView(kind: kind, mediaProvider: mediaProvider)
        if let hostingController {
            hostingController.rootView = AnyView(markerView)
        } else {
            let hostingController = UIHostingController(rootView: AnyView(markerView))
            self.hostingController = hostingController
            hostingController.view.backgroundColor = .clear
            addSubview(hostingController.view)
        }

        guard let hostedView = hostingController?.view else { return }
        let size = hostedView.intrinsicContentSize
        bounds = CGRect(origin: .zero, size: size)
        hostedView.frame = bounds
        centerOffset = CGPoint(x: 0, y: -size.height / 2)
    }
}
