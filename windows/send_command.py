#!/usr/bin/env python3
"""
Hermes Command CLI Sender
Sends protocol commands (start_listening, stop_listening, ping) directly over TCP port 9999
and streams JSON protocol responses cleanly over socket.
"""

import sys
import json
import socket
import time

def send(cmd_name: str, host: str = "127.0.0.1", port: int = 9999):
    payload = {
        "version": "1.0",
        "type": "command",
        "command": cmd_name,
        "timestamp": int(time.time() * 1000)
    }
    
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(120.0)
        s.connect((host, port))
        
        # Send command payload
        raw_msg = (json.dumps(payload) + "\n").encode("utf-8")
        s.sendall(raw_msg)
        print(f"✅ Sent command '{cmd_name}' to Hermes Android server at {host}:{port}")
        
        # Stream response JSON lines
        buffer = ""
        while True:
            try:
                chunk = s.recv(4096).decode("utf-8")
                if not chunk:
                    break
                buffer += chunk
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    line = line.strip()
                    if line:
                        msg = json.loads(line)
                        mtype = msg.get("type")
                        
                        if mtype == "heartbeat":
                            print(f"💓 [HEARTBEAT]: Android Server Status '{msg.get('status')}'")
                        elif mtype == "partial":
                            print(f"  ... Partial #{msg.get('sequence', 0)}: \"{msg.get('text')}\"")
                        elif mtype == "final":
                            print(f"\n✨ [FINAL SPEECH TEXT]: \"{msg.get('text')}\"\n")
                            s.close()
                            return
                        elif mtype == "error":
                            print(f"\n❌ [ERROR]: {msg.get('code')} - {msg.get('message')}\n")
                            s.close()
                            return
            except socket.timeout:
                print("⏱️ Socket timeout waiting for speech response.")
                break
        s.close()
    except Exception as e:
        print(f"❌ Failed to send command to {host}:{port}: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 windows/send_command.py <start|stop|ping>")
        sys.exit(1)
        
    cmd_arg = sys.argv[1].lower()
    if cmd_arg in ["start", "listen"]:
        send("start_listening")
    elif cmd_arg in ["stop", "end"]:
        send("stop_listening")
    elif cmd_arg in ["ping", "heartbeat"]:
        send("ping")
    else:
        print(f"Unknown command: {cmd_arg}. Use 'start', 'stop', or 'ping'.")
