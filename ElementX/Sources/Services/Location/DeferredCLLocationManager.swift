//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreLocation

final class DeferredCLLocationManager: CLLocationManagerProtocol {
    private let makeLocationManager: () -> CLLocationManagerProtocol
    private var locationManager: CLLocationManagerProtocol?
    
    weak var delegate: CLLocationManagerDelegate? {
        didSet {
            locationManager?.delegate = delegate
        }
    }
    
    var allowsBackgroundLocationUpdates = false {
        didSet {
            locationManager?.allowsBackgroundLocationUpdates = allowsBackgroundLocationUpdates
        }
    }
    
    var showsBackgroundLocationIndicator = false {
        didSet {
            locationManager?.showsBackgroundLocationIndicator = showsBackgroundLocationIndicator
        }
    }
    
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest {
        didSet {
            locationManager?.desiredAccuracy = desiredAccuracy
        }
    }
    
    var distanceFilter: CLLocationDistance = kCLDistanceFilterNone {
        didSet {
            locationManager?.distanceFilter = distanceFilter
        }
    }
    
    var pausesLocationUpdatesAutomatically = true {
        didSet {
            locationManager?.pausesLocationUpdatesAutomatically = pausesLocationUpdatesAutomatically
        }
    }
    
    var authorizationStatus: CLAuthorizationStatus {
        locationManager?.authorizationStatus ?? CLLocationManager.authorizationStatus()
    }
    
    var accuracyAuthorization: CLAccuracyAuthorization {
        locationManager?.accuracyAuthorization ?? .fullAccuracy
    }
    
    init(makeLocationManager: @escaping () -> CLLocationManagerProtocol = { CLLocationManager() }) {
        self.makeLocationManager = makeLocationManager
    }
    
    func requestAlwaysAuthorization() {
        resolvedLocationManager.requestAlwaysAuthorization()
    }
    
    func startUpdatingLocation() {
        resolvedLocationManager.startUpdatingLocation()
    }
    
    func stopUpdatingLocation() {
        resolvedLocationManager.stopUpdatingLocation()
    }
    
    private var resolvedLocationManager: CLLocationManagerProtocol {
        if let locationManager {
            return locationManager
        }
        
        let locationManager = makeLocationManager()
        locationManager.delegate = delegate
        locationManager.allowsBackgroundLocationUpdates = allowsBackgroundLocationUpdates
        locationManager.showsBackgroundLocationIndicator = showsBackgroundLocationIndicator
        locationManager.desiredAccuracy = desiredAccuracy
        locationManager.distanceFilter = distanceFilter
        locationManager.pausesLocationUpdatesAutomatically = pausesLocationUpdatesAutomatically
        self.locationManager = locationManager
        return locationManager
    }
}
