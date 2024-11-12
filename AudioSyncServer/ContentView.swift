import SwiftUI
import Network
import AVFoundation

import SwiftUI
import Network
import AVFoundation

struct AudioPacket {
    var timestamp: UInt64
    var payload: Data
    
    func serializedData() -> Data {
        var data = Data()
        var timestampBigEndian = timestamp.bigEndian
        data.append(Data(bytes: &timestampBigEndian, count: MemoryLayout<UInt64>.size))
        data.append(payload)
        return data
    }
}

struct Client: Identifiable {
    let id = UUID()
    let name: String
    var connection: NWConnection?
    var isSelected: Bool = false
    var isConnected: Bool = true
}

class NetworkManager: ObservableObject {
    @Published var clients: [Client] = []
    @Published var isCapturing = false
    @Published var isTestMode = false // New property to control test mode
    private var listener: NWListener?
    private let audioEngine = AVAudioEngine()
    
    func startListening() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.acceptLocalOnly = false
            
            let port = NWEndpoint.Port(rawValue: 12345)!
            listener = try NWListener(using: parameters, on: port)
            listener?.service = NWListener.Service(name: "AudioSyncService", type: "_audiosync._tcp")
            
            setupListenerHandlers()
            listener?.start(queue: DispatchQueue.main)
            
            startAudioCapture()
            
            print("Server is listening on port 12345")
        } catch {
            print("Failed to start listener: \(error.localizedDescription)")
        }
    }
    
    private func setupListenerHandlers() {
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("Listener ready on port 12345")
            case .failed(let error):
                print("Listener failed with error: \(error.localizedDescription)")
                self?.stopListening()
            case .cancelled:
                print("Listener cancelled")
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            print("New connection established")
            self?.handleNewConnection(connection)
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let clientName = "Client \(self.clients.count + 1)"
        let newClient = Client(name: clientName, connection: connection)
        
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleConnectionState(state, for: newClient)
            }
        }
        
        connection.start(queue: .main)
        
        DispatchQueue.main.async {
            self.clients.append(newClient)
            print("Client added: \(clientName)")
        }
    }
    
    private func handleConnectionState(_ state: NWConnection.State, for client: Client) {
        switch state {
        case .ready:
            print("\(client.name) connected")
            if let index = clients.firstIndex(where: { $0.id == client.id }) {
                clients[index].isConnected = true
            }
        case .failed(let error):
            print("\(client.name) connection failed: \(error.localizedDescription)")
            removeClient(client)
        case .cancelled:
            print("\(client.name) connection cancelled")
            removeClient(client)
        default:
            break
        }
    }
    
    private func removeClient(_ client: Client) {
        DispatchQueue.main.async {
            self.clients.removeAll(where: { $0.id == client.id })
            print("Client removed: \(client.name)")
        }
    }
    
    func stopListening() {
        isCapturing = false
        
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        
        for client in clients {
            client.connection?.cancel()
        }
        
        listener?.cancel()
        listener = nil
        
        DispatchQueue.main.async {
            self.clients.removeAll()
        }
        
        print("Server stopped")
    }
    
    private func startAudioCapture() {
        guard !isCapturing else { return }
        
        if isTestMode {
            generateSyntheticBeep()
        } else {
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
                guard let self = self, self.isCapturing else { return }
                
                let data = self.audioBufferToData(buffer)
                let timestamp = UInt64(time.hostTime)
                let packet = AudioPacket(timestamp: timestamp, payload: data)
                
                print("Captured audio packet with timestamp: \(timestamp)")
                self.broadcastAudioPacket(packet)
            }
            
            do {
                try audioEngine.start()
                isCapturing = true
                print("Audio engine started, capturing audio")
            } catch {
                print("Failed to start audio engine: \(error.localizedDescription)")
            }
        }
    }
    
    private func generateSyntheticBeep() {
        let beepDuration = 0.2
        let sampleRate = 44100
        let frequency = 440.0 // A4 tone frequency
        
        let samples = Int(beepDuration * Double(sampleRate))
        var data = Data()
        
        for i in 0..<samples {
            let sample = sin(2.0 * .pi * frequency * Double(i) / Double(sampleRate))
            let int16Sample = Int16(sample * Double(Int16.max))
            var bigEndianSample = int16Sample.bigEndian
            data.append(Data(bytes: &bigEndianSample, count: MemoryLayout<Int16>.size))
        }
        
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let packet = AudioPacket(timestamp: timestamp, payload: data)
        
        print("Generated synthetic beep with timestamp: \(timestamp)")
        broadcastAudioPacket(packet)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + beepDuration) { [weak self] in
            if self?.isTestMode == true {
                self?.generateSyntheticBeep()
            }
        }
    }
    
    private func audioBufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let stride = channelCount * 2
        
        var data = Data(capacity: frameLength * stride)
        
        if let floatData = buffer.floatChannelData {
            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    let sample = floatData[channel][frame]
                    let int16Sample = Int16(sample * Float(Int16.max))
                    var bigEndianSample = int16Sample.bigEndian
                    data.append(Data(bytes: &bigEndianSample, count: MemoryLayout<Int16>.size))
                }
            }
        }
        
        return data
    }
    
    private func broadcastAudioPacket(_ packet: AudioPacket) {
        let packetData = packet.serializedData()
        
        for client in clients where client.isConnected {
            client.connection?.send(content: packetData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    print("Failed to send audio packet to \(client.name): \(error.localizedDescription)")
                    if let self = self {
                        DispatchQueue.main.async {
                            if let index = self.clients.firstIndex(where: { $0.id == client.id }) {
                                self.clients[index].isConnected = false
                            }
                        }
                    }
                } else {
                    print("Audio packet sent to \(client.name)")
                }
            })
        }
    }
}


struct ContentView: View {
    @StateObject private var networkManager = NetworkManager()
    
    var body: some View {
        VStack {
            Text("Audio Sync Server")
                .font(.largeTitle)
                .padding()
            
            Button(action: {
                if networkManager.isCapturing {
                    networkManager.stopListening()
                } else {
                    networkManager.startListening()
                }
            }) {
                Text(networkManager.isCapturing ? "Stop Broadcast" : "Start Broadcast")
                    .font(.headline)
                    .padding()
                    .foregroundColor(.white)
                    .background(networkManager.isCapturing ? Color.red : Color.green)
                    .cornerRadius(8)
            }
            
            Button(action: {
                networkManager.isTestMode.toggle()
            }) {
                Text(networkManager.isTestMode ? "Disable Test" : "Enable Test")
                    .font(.headline)
                    .padding()
                    .foregroundColor(.white)
                    .background(networkManager.isTestMode ? Color.blue : Color.gray)
                    .cornerRadius(8)
            }
            
            Divider().padding(.vertical)
            
            List {
                ForEach(networkManager.clients) { client in
                    HStack {
                        Text(client.name)
                            .font(.subheadline)
                        Spacer()
                        Text(client.isConnected ? "Connected" : "Disconnected")
                            .foregroundColor(client.isConnected ? .green : .red)
                            .font(.caption)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleClient(client)
                    }
                }
            }
            .padding(.horizontal)
            .frame(maxHeight: .infinity)
        }
        .padding()
    }
    
    private func toggleClient(_ client: Client) {
        if let index = networkManager.clients.firstIndex(where: { $0.id == client.id }) {
            networkManager.clients[index].isSelected.toggle()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

