import serial
import time
import struct
import math

# Configure your COM port here (the one connected to your Android device via an adapter)
COM_PORT = 'COM3' 
BAUD_RATE = 500000

print("=== ESP32 Telemetry Simulator ===")

try:
    ser = serial.Serial(COM_PORT, BAUD_RATE)
    print(f"Connected to {COM_PORT} successfully. Sending data...")
except Exception as e:
    print(f"Warning: Could not open {COM_PORT}: {e}")
    print("Printing to console instead for preview:\n")
    ser = None

start_time = time.time()

def send_frame(can_id, hex_data):
    ts = time.time() - start_time
    sec = int(ts)
    rem = int((ts - sec) * 1000)
    
    # Format matches the ESP32 printf you provided exactly:
    line = f"({sec}.{rem:03d}) can0 {can_id:03X}#{hex_data}\n"
    
    if ser:
        ser.write(line.encode('utf-8'))
    else:
        print(line.strip())

try:
    while True:
        t = time.time()
        
        # 1. Simulate Pedal (ID: 0x110)
        # Throttle sweeps smoothly using a sine wave, brake flashes every 4 seconds
        throttle = int((math.sin(t) + 1) * 60) # Range: 0 to 120 raw
        brake = 1 if (int(t) % 4 == 0) else 0
        pedal_raw = (throttle << 1) | brake
        send_frame(0x110, f"{pedal_raw:02X}")

        # 2. Simulate Main Power 780 (ID: 0x310)
        # Base 72V, dips slightly when throttle is high. Amps scale with throttle.
        volts = 72.0 - (throttle * 0.05)
        amps = throttle * 1.5
        volts_raw = int(volts / 0.003125)
        amps_raw = int(amps / 0.0024)
        
        # Pack as 2-byte unsigned short (volts) and 2-byte signed short (amps) in Little Endian
        power_data = struct.pack('<H h', volts_raw, amps_raw)
        send_frame(0x310, power_data.hex().upper())
        
        # 3. Simulate Controls (ID: 0x210)
        # Blink left turn signal steadily, keep headlights on (bit 4 -> 0x08)
        left_turn = 1 if int(t * 2) % 2 == 0 else 0
        headlights = 0x08
        aux_raw = left_turn | headlights
        send_frame(0x210, f"{aux_raw:02X}")

        # Send data at 10Hz (100ms)
        time.sleep(0.1) 
        
except KeyboardInterrupt:
    print("\nStopped simulation.")
