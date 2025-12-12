#!/usr/bin/env python3

import os
import argparse
import fcntl
import struct
import select
import subprocess
import sys
import threading
import time
import traceback

def open_tap(name):
    TUNSETIFF = 0x400454ca
    IFF_TAP = 0x0002
    IFF_NO_PI = 0x1000
    
    # Solo intentamos abrir una vez. Si falla, es fatal porque la interfaz
    # YA DEBERÍA EXISTIR gracias a docker_vm.py
    try:
        print(f"DEBUG: Opening /dev/net/tun for attaching to '{name}'...", file=sys.stderr)
        tun = os.open('/dev/net/tun', os.O_RDWR)
        
        # Preparamos el struct para TUNSETIFF
        # Esto le dice al Kernel: "Quiero controlar la interfaz 'name' existente"
        ifr = struct.pack('16sH', name.encode()[:15], IFF_TAP | IFF_NO_PI)
        
        # Adjuntamos el file descriptor a la interfaz
        fcntl.ioctl(tun, TUNSETIFF, ifr)
        
        print(f"DEBUG: Successfully attached to TAP '{name}'", file=sys.stderr)
        
        # --- SECCIÓN ELIMINADA ---
        # No intentamos ponerla UP aquí. Eso se hace en el host con 'ip link set up'.
        # Intentar hacerlo aquí con el fd del tun genera Errno 22.
        # -------------------------
        
        return tun
            
    except Exception as e:
        print(f"ERROR attaching to TAP {name}: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
        
def read_stderr(proc, cid):
    """Lee stderr del agente y lo imprime"""
    print(f"DEBUG: Starting stderr reader thread for container {cid}", file=sys.stderr)
    try:
        while True:
            line = proc.stderr.readline()
            if line:
                print(f"[Agent@{cid}] {line.decode()}", file=sys.stderr, end='')
            else:
                print(f"DEBUG: Agent stderr closed for {cid}", file=sys.stderr)
                break
    except Exception as e:
        print(f"ERROR in stderr reader: {e}", file=sys.stderr)

# Redirigir stderr a un archivo para depurar
sys.stderr = open('/tmp/gns3_proxy_debug.log', 'a')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--tap', required=True)
    p.add_argument('--cid', required=True, help="Container ID")
    p.add_argument('--agent-path', required=True, help="Path to agent binary inside container")
    p.add_argument('--ifname', required=True, help="Interface name inside container")
    p.add_argument('--mac', required=False, help="MAC address")
    args = p.parse_args()

    print(f"=== GNS3 Proxy Starting ===", file=sys.stderr)
    print(f"Timestamp: {time.ctime()}", file=sys.stderr)
    print(f"TAP: {args.tap}", file=sys.stderr)
    print(f"Container: {args.cid}", file=sys.stderr)
    print(f"Agent: {args.agent_path}", file=sys.stderr)
    print(f"Interface: {args.ifname}", file=sys.stderr)
    print(f"MAC: {args.mac}", file=sys.stderr)
    print(f"Python version: {sys.version}", file=sys.stderr)
    print(f"Current user: {os.getuid()}/{os.geteuid()}", file=sys.stderr)

    # 1. Abrir TAP
    print(f"\nDEBUG: Step 1 - Opening TAP device...", file=sys.stderr)
    tap_fd = open_tap(args.tap)
    print(f"DEBUG: TAP {args.tap} opened (fd={tap_fd})", file=sys.stderr)

    # 2. Construir comando para el AGENTE BINARIO
    print(f"\nDEBUG: Step 2 - Building agent command...", file=sys.stderr)
    cmd = [
        'podman', 'exec', '-i', args.cid,
        args.agent_path,
        '--ifname', args.ifname
    ]
    if args.mac:
        cmd.extend(['--mac', args.mac])

    print(f"DEBUG: Full command: {' '.join(cmd)}", file=sys.stderr)
    
    # Verificar si el contenedor existe
    print(f"DEBUG: Checking if container {args.cid} exists...", file=sys.stderr)
    check_cmd = ['podman', 'ps', '-q', '--filter', f'id={args.cid}']
    result = subprocess.run(check_cmd, capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.strip():
        print(f"ERROR: Container {args.cid} not found or not running!", file=sys.stderr)
        print(f"DEBUG: podman ps output: {result.stdout}", file=sys.stderr)
        os.close(tap_fd)
        sys.exit(1)
    print(f"DEBUG: Container {args.cid} is running", file=sys.stderr)

    # 3. Lanzar el proceso del agente
    print(f"\nDEBUG: Step 3 - Launching agent process...", file=sys.stderr)
    try:
        proc = subprocess.Popen(cmd, 
                              stdin=subprocess.PIPE, 
                              stdout=subprocess.PIPE, 
                              stderr=subprocess.PIPE,
                              bufsize=0)
        print(f"DEBUG: Agent process started with PID {proc.pid}", file=sys.stderr)
        
        # Esperar un momento para ver si el agente muere inmediatamente
        time.sleep(0.5)
        if proc.poll() is not None:
            print(f"ERROR: Agent process died immediately with exit code {proc.returncode}", file=sys.stderr)
            # Leer cualquier salida del agente
            stdout, stderr = proc.communicate()
            print(f"DEBUG: Agent stdout: {stdout[:200]}", file=sys.stderr)
            print(f"DEBUG: Agent stderr: {stderr[:200]}", file=sys.stderr)
            os.close(tap_fd)
            sys.exit(1)
            
    except Exception as e:
        print(f"ERROR: Failed to start agent process: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        os.close(tap_fd)
        sys.exit(1)

    # Hilo para leer stderr del agente
    print(f"DEBUG: Starting stderr reader thread...", file=sys.stderr)
    stderr_thread = threading.Thread(target=read_stderr, args=(proc, args.cid[:8]), daemon=True)
    stderr_thread.start()

    print(f"\nDEBUG: Proxy bridge initialized: {args.tap} <-> {args.cid}:{args.ifname}", file=sys.stderr)
    print(f"DEBUG: Entering main bridge loop...", file=sys.stderr)

    # 4. Bucle de retransmisión
    loop_count = 0
    try:
        while True:
            loop_count += 1
            if loop_count % 100 == 0:
                print(f"DEBUG: Bridge loop iteration {loop_count}", file=sys.stderr)
            
            readable, _, _ = select.select([tap_fd, proc.stdout], [], [], 1.0)
            
            if not readable:
                # Timeout - verificar que el agente sigue vivo
                if proc.poll() is not None:
                    print(f"ERROR: Agent process exited with code {proc.returncode}", file=sys.stderr)
                    break
                continue

            if tap_fd in readable:
                data = os.read(tap_fd, 65535)
                if not data: 
                    print("ERROR: TAP device closed", file=sys.stderr)
                    break
                print(f"DEBUG: Read {len(data)} bytes from TAP", file=sys.stderr)
                try:
                    written = proc.stdin.write(data)
                    proc.stdin.flush()
                    print(f"DEBUG: Wrote {written} bytes to agent stdin", file=sys.stderr)
                except BrokenPipeError:
                    print("ERROR: Agent stdin broken pipe", file=sys.stderr)
                    break

            if proc.stdout in readable:
                data = os.read(proc.stdout.fileno(), 65535)
                if not data: 
                    print("ERROR: Agent stdout closed", file=sys.stderr)
                    break
                print(f"DEBUG: Read {len(data)} bytes from agent stdout", file=sys.stderr)
                written = os.write(tap_fd, data)
                print(f"DEBUG: Wrote {written} bytes to TAP", file=sys.stderr)
                
            if proc.poll() is not None:
                print(f"ERROR: Agent process exited with code {proc.returncode}", file=sys.stderr)
                break

    except KeyboardInterrupt:
        print("\nDEBUG: Proxy interrupted by user", file=sys.stderr)
    except Exception as e:
        print(f"ERROR in bridge loop: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
    finally:
        print("\nDEBUG: Cleaning up...", file=sys.stderr)
        if proc.poll() is None:
            print("DEBUG: Terminating agent process...", file=sys.stderr)
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                print("DEBUG: Agent did not terminate, killing...", file=sys.stderr)
                proc.kill()
        os.close(tap_fd)
        print("DEBUG: Proxy shutdown complete", file=sys.stderr)

if __name__ == '__main__':
    main()
