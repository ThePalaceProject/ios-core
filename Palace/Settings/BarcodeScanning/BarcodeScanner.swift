//
//  BarcodeScanner.swift
//  Palace
//
//  Created by Vladimir Fedorov on 07/04/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import AVFoundation
import UIKit

fileprivate extension CGRect {
  func contains(_ rect: CGRect) -> Bool {
    self.minX <= rect.minX && self.maxX >= rect.maxX && self.minY <= rect.minY && self.maxY >= rect.maxY
  }
}

class BarcodeScanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  private var captureSession: AVCaptureSession!
  private var previewLayer: AVCaptureVideoPreviewLayer!
  private var scannerView: UIView!
  private var previewView = UIView(frame: .zero)
  
  private var completion: (_ barcode: String?) -> Void
  
  
  init(completion: @escaping (_ barcode: String?) -> Void) {
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    view.backgroundColor = UIColor.black
    captureSession = AVCaptureSession()
    
    guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else { return }
    let videoInput: AVCaptureDeviceInput
    
    do {
      videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
    } catch {
      return
    }
    
    if (captureSession.canAddInput(videoInput)) {
      captureSession.addInput(videoInput)
    } else {
      showError()
      return
    }
    
    let metadataOutput = AVCaptureMetadataOutput()
    
    if (captureSession.canAddOutput(metadataOutput)) {
      captureSession.addOutput(metadataOutput)
      
      metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
      if #available(iOS 15.4, *) {
        metadataOutput.metadataObjectTypes = [.code39, .code128, .qr, .codabar]
      } else {
        metadataOutput.metadataObjectTypes = [.code39, .code128, .qr]
      }
    } else {
      showError()
      return
    }
    
    // Camera view
    previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    previewLayer.frame = view.layer.bounds
    previewLayer.videoGravity = .resizeAspectFill
    view.layer.addSublayer(previewLayer)
    
    // Scanner view
    scannerView = UIView(frame: .zero)
    scannerView.layer.borderColor = UIColor.systemRed.cgColor
    scannerView.layer.borderWidth = 4
    scannerView.layer.cornerRadius = 10
    view.addSubview(scannerView)
    scannerView.translatesAutoresizingMaskIntoConstraints = false
    let scannerViewContraints = [
      scannerView.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5, constant: -20),
      scannerView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 1, constant: -20),
      scannerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      scannerView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
    ]
    NSLayoutConstraint.activate(scannerViewContraints)
    previewView.layer.borderColor = UIColor.green.cgColor
    previewView.layer.borderWidth = 4
    view.addSubview(previewView)

    let cancelButton = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction(handler: { _ in
      self.stopCaptureSession()
      self.dismiss(animated: true)
    }))
    navigationItem.rightBarButtonItem = cancelButton
    
    startCaptureSession()
  }
  
  private func startCaptureSession() {
    //-[AVCaptureSession startRunning] should be called from background thread. Calling it on the main thread can lead to UI unresponsiveness
    DispatchQueue.global(qos: .background).async {
      if !self.captureSession.isRunning {
        self.captureSession.startRunning()
      }
    }
  }

  private func stopCaptureSession() {
    //-[AVCaptureSession startRunning] should be called from background thread. Calling it on the main thread can lead to UI unresponsiveness
    DispatchQueue.global(qos: .background).async {
      if self.captureSession.isRunning {
        self.captureSession.stopRunning()
      }
    }
  }

  private func showError() {
    let ac = UIAlertController(
      title: Strings.TPPBarCode.cameraAccessDisabledTitle,
      message: Strings.TPPBarCode.cameraAccessDisabledBody,
      preferredStyle: .alert)
    ac.addAction(UIAlertAction(title: Strings.Generic.ok, style: .default))
    present(ac, animated: true)
    captureSession = nil
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    startCaptureSession()
  }
  
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopCaptureSession()
  }
  
  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    
    let barcodes = metadataObjects
      .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
      .filter { metadataObject in
        // transforms coordinates
        let barcodeObject = previewLayer.transformedMetadataObject(for: metadataObject) as! AVMetadataMachineReadableCodeObject
        return scannerView.frame.contains(barcodeObject.bounds)
      }
    if barcodes.count == 1, let value = barcodes.first?.stringValue {
      completion(value)
      stopCaptureSession()
      dismiss(animated: true)
    }
    
  }
  
}
