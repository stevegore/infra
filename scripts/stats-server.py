#!/usr/bin/env python3
"""Simple stats server for pico and OKE cluster metrics."""

import json
import subprocess
import shutil
from datetime import datetime
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
import os

class StatsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/stats':
            stats = get_stats()
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(stats).encode())
        elif self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            html = render_html(get_stats())
            self.wfile.write(html.encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress logs

def get_pico_stats():
    """Get pico resource stats."""
    try:
        # Disk usage
        result = subprocess.run(['df', '-B1', '/'], capture_output=True, text=True)
        lines = result.stdout.strip().split('\n')
        disk_data = lines[1].split()
        disk_total = int(disk_data[1])
        disk_used = int(disk_data[2])
        disk_available = int(disk_data[3])

        # Media disk
        result = subprocess.run(['df', '-B1', '/media/m2'], capture_output=True, text=True)
        lines = result.stdout.strip().split('\n')
        media_data = lines[1].split()
        media_total = int(media_data[1])
        media_used = int(media_data[2])

        # Memory
        result = subprocess.run(['free', '-b'], capture_output=True, text=True)
        lines = result.stdout.strip().split('\n')
        mem_data = lines[1].split()
        mem_total = int(mem_data[1])
        mem_used = int(mem_data[2])
        mem_available = int(mem_data[6])

        # CPU count
        cpu_count = os.cpu_count() or 1

        return {
            'hostname': 'pico',
            'status': 'online',
            'disk_root': {
                'total_gb': round(disk_total / 1e9, 1),
                'used_gb': round(disk_used / 1e9, 1),
                'available_gb': round(disk_available / 1e9, 1),
                'percent': round(100 * disk_used / disk_total, 1),
            },
            'disk_media': {
                'total_tb': round(media_total / 1e12, 2),
                'used_tb': round(media_used / 1e12, 2),
                'available_tb': round((media_total - media_used) / 1e12, 2),
                'percent': round(100 * media_used / media_total, 1),
            },
            'memory': {
                'total_gb': round(mem_total / 1e9, 1),
                'used_gb': round(mem_used / 1e9, 1),
                'available_gb': round(mem_available / 1e9, 1),
                'percent': round(100 * mem_used / mem_total, 1),
            },
            'cpu_cores': cpu_count,
        }
    except Exception as e:
        return {'error': str(e), 'hostname': 'pico', 'status': 'error'}

def get_oke_stats():
    """Get OKE cluster stats."""
    try:
        # Try to find kubectl in PATH or home directory
        kubectl_paths = [
            'kubectl',
            '/home/steve/kubectl',
            '/usr/local/bin/kubectl',
            '/snap/bin/kubectl',
        ]
        kubectl_cmd = None
        for path in kubectl_paths:
            try:
                # Check if the file exists and is executable
                if os.path.isfile(path) and os.access(path, os.X_OK):
                    kubectl_cmd = path
                    break
            except (OSError, subprocess.TimeoutExpired):
                continue

        if not kubectl_cmd:
            return {
                'cluster': 'homelab',
                'status': 'unavailable',
                'message': 'kubectl not installed'
            }

        kubeconfig_path = os.path.expanduser('~/.kube/oke-homelab.config')
        if not os.path.exists(kubeconfig_path):
            return {
                'cluster': 'homelab',
                'status': 'unavailable',
                'message': 'kubeconfig not found on pico'
            }

        # Try to get node info from kubeconfig
        result = subprocess.run(
            [kubectl_cmd, f'--kubeconfig={kubeconfig_path}',
             'get', 'nodes', '-o', 'json'],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return {
                'cluster': 'homelab',
                'status': 'unavailable',
                'message': 'kubeconfig not accessible'
            }

        data = json.loads(result.stdout)
        nodes = []
        total_cpu = 0
        total_memory = 0

        for node in data.get('items', []):
            metadata = node.get('metadata', {})
            status = node.get('status', {})
            capacity = status.get('capacity', {})

            cpu_str = capacity.get('cpu', '0')
            mem_str = capacity.get('memory', '0Ki')

            # Parse CPU (can be "2" or "2000m")
            if 'm' in cpu_str:
                cpu = float(cpu_str.replace('m', '')) / 1000
            else:
                cpu = float(cpu_str)

            # Parse memory (Ki, Mi, Gi)
            mem_val = float(mem_str.rstrip('KMG'))
            if mem_str.endswith('Ki'):
                mem_gb = mem_val / (1024 ** 2)
            elif mem_str.endswith('Mi'):
                mem_gb = mem_val / 1024
            elif mem_str.endswith('Gi'):
                mem_gb = mem_val
            else:
                mem_gb = mem_val / 1e9

            total_cpu += cpu
            total_memory += mem_gb

            nodes.append({
                'name': metadata.get('name', 'unknown'),
                'status': status.get('conditions', [{}])[-1].get('type', 'Unknown'),
                'cpu_ocpu': round(cpu, 1),
                'memory_gb': round(mem_gb, 0),
            })

        return {
            'cluster': 'homelab',
            'status': 'active',
            'version': data.get('apiVersion', 'unknown'),
            'node_count': len(nodes),
            'nodes': sorted(nodes, key=lambda x: x['name']),
            'total_capacity': {
                'cpu_ocpu': round(total_cpu, 1),
                'memory_gb': round(total_memory, 0),
            }
        }
    except Exception as e:
        return {'cluster': 'homelab', 'status': 'error', 'error': str(e)}

def get_stats():
    """Get all stats."""
    return {
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'pico': get_pico_stats(),
        'oke': get_oke_stats(),
    }

def render_html(stats):
    """Render simple HTML dashboard."""
    pico = stats.get('pico', {})
    oke = stats.get('oke', {})

    pico_disk_alert = '⚠️' if pico.get('disk_root', {}).get('percent', 0) > 85 else '✓'

    html = f"""
    <html>
    <head>
        <title>Homelab Stats</title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body {{ font-family: monospace; background: #1e1e1e; color: #e0e0e0; margin: 20px; }}
            .container {{ max-width: 1200px; margin: 0 auto; }}
            .card {{ background: #2d2d2d; border: 1px solid #444; border-radius: 4px; padding: 16px; margin: 16px 0; }}
            .stat-row {{ display: grid; grid-template-columns: 150px 1fr; gap: 16px; margin: 8px 0; }}
            .stat-label {{ font-weight: bold; color: #888; }}
            .stat-value {{ color: #4fc3f7; }}
            .stat-critical {{ color: #f44336; }}
            .progress {{ background: #444; height: 20px; border-radius: 2px; overflow: hidden; margin: 4px 0; }}
            .progress-bar {{ height: 100%; background: #4fc3f7; transition: width 0.3s; }}
            .progress-bar.warning {{ background: #ff9800; }}
            .progress-bar.critical {{ background: #f44336; }}
            h2 {{ border-bottom: 1px solid #444; padding-bottom: 8px; margin-top: 0; }}
            .nodes {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 12px; }}
            .node {{ background: #252525; padding: 12px; border-radius: 4px; border-left: 3px solid #4fc3f7; }}
        </style>
    </head>
    <body>
        <div class="container">
            <h1>🏠 Homelab Stats</h1>
            <p style="color: #888;">Last updated: {stats.get('timestamp', 'unknown')}</p>

            <div class="card">
                <h2>Pico Server {pico_disk_alert}</h2>
                <div class="stat-row">
                    <div class="stat-label">Status</div>
                    <div class="stat-value">{pico.get('status', 'unknown')}</div>
                </div>
                <div class="stat-row">
                    <div class="stat-label">CPU Cores</div>
                    <div class="stat-value">{pico.get('cpu_cores', '?')}</div>
                </div>
                <div class="stat-row">
                    <div class="stat-label">RAM</div>
                    <div class="stat-value">{pico.get('memory', {}).get('used_gb', '?')} / {pico.get('memory', {}).get('total_gb', '?')} GB</div>
                </div>
                <div class="progress">
                    <div class="progress-bar" style="width: {pico.get('memory', {}).get('percent', 0)}%"></div>
                </div>
                <div class="stat-row">
                    <div class="stat-label">Root Disk</div>
                    <div class="stat-value" style="{'color: #f44336;' if pico.get('disk_root', {}).get('percent', 0) > 85 else ''}">{pico.get('disk_root', {}).get('used_gb', '?')} / {pico.get('disk_root', {}).get('total_gb', '?')} GB ({pico.get('disk_root', {}).get('percent', 0)}%)</div>
                </div>
                <div class="progress">
                    <div class="progress-bar {'critical' if pico.get('disk_root', {}).get('percent', 0) > 85 else 'warning' if pico.get('disk_root', {}).get('percent', 0) > 70 else ''}" style="width: {pico.get('disk_root', {}).get('percent', 0)}%"></div>
                </div>
                <div class="stat-row">
                    <div class="stat-label">Media (/media/m2)</div>
                    <div class="stat-value">{pico.get('disk_media', {}).get('used_tb', '?')} / {pico.get('disk_media', {}).get('total_tb', '?')} TB ({pico.get('disk_media', {}).get('percent', 0)}%)</div>
                </div>
                <div class="progress">
                    <div class="progress-bar" style="width: {min(pico.get('disk_media', {}).get('percent', 0), 100)}%"></div>
                </div>
            </div>

            <div class="card">
                <h2>OKE Cluster</h2>
                <div class="stat-row">
                    <div class="stat-label">Cluster</div>
                    <div class="stat-value">{oke.get('cluster', 'unknown')}</div>
                </div>
                <div class="stat-row">
                    <div class="stat-label">Status</div>
                    <div class="stat-value">{oke.get('status', 'unknown')}</div>
                </div>
                <div class="stat-row">
                    <div class="stat-label">Nodes</div>
                    <div class="stat-value">{oke.get('node_count', 0)}</div>
                </div>
                <div class="stat-row">
                    <div class="stat-label">Total Capacity</div>
                    <div class="stat-value">{oke.get('total_capacity', {}).get('cpu_ocpu', 0)} OCPU / {oke.get('total_capacity', {}).get('memory_gb', 0)} GB</div>
                </div>
                <h3 style="margin-top: 16px; margin-bottom: 8px;">Nodes</h3>
                <div class="nodes">
    """

    for node in oke.get('nodes', []):
        html += f"""
                    <div class="node">
                        <div style="font-weight: bold;">{node.get('name', 'unknown')}</div>
                        <div style="color: #888; font-size: 0.9em;">Status: {node.get('status', 'unknown')}</div>
                        <div style="margin-top: 4px;">{node.get('cpu_ocpu', 0)} OCPU / {node.get('memory_gb', 0)} GB</div>
                    </div>
        """

    html += """
                </div>
            </div>
        </div>
    </body>
    </html>
    """
    return html

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8001), StatsHandler)
    print('Stats server running on port 8001')
    server.serve_forever()
