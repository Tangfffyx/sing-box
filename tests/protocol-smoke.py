#!/usr/bin/env python3
"""Real TCP/UDP loopback tests of all eight production protocol builders."""
import contextlib, functools, http.server, json, os, pathlib, socket, struct, subprocess, sys, tempfile, threading, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = os.environ.get('SB_TEST_CORE', '/usr/local/bin/sing-box')
PROTOCOLS = ['reality', 'anytls', 'shadowsocks', 'socks', 'trojan', 'vmess-ws', 'vless-ws', 'tuic']

def free_base():
    for base in range(32000, 54000, 37):
        sockets = []
        try:
            for port in range(base, base+12):
                for kind in [socket.SOCK_STREAM, socket.SOCK_DGRAM]:
                    s = socket.socket(socket.AF_INET, kind); sockets.append(s); s.bind(('127.0.0.1', port))
            return base
        except OSError:
            continue
        finally:
            for s in sockets: s.close()
    raise RuntimeError('no free fixture ports')

@contextlib.contextmanager
def process(args, log):
    with open(log, 'w') as output:
        p = subprocess.Popen(args, stdout=output, stderr=output)
        try:
            time.sleep(.5)
            if p.poll() is not None: raise RuntimeError(pathlib.Path(log).read_text())
            yield p
        finally:
            if p.poll() is None:
                p.terminate()
                try: p.wait(timeout=5)
                except subprocess.TimeoutExpired: p.kill(); p.wait()

def outbound(ib, public):
    user = next(u for u in ib['users'] if (u.get('name') or u.get('username')).endswith('@alice'))
    out = {'type':ib['type'], 'tag':'proxy', 'server':'127.0.0.1', 'server_port':ib['listen_port']}
    for key in ['uuid','password','flow','username']:
        if key in user: out[key] = user[key]
    if ib['type'] == 'shadowsocks':
        out.update(method=ib['method'], password=ib['password']+':'+user['password'])
    if ib['type'] == 'vmess': out.update(security='auto', alter_id=0)
    if 'transport' in ib: out['transport'] = ib['transport']
    if 'tls' in ib:
        out['tls'] = {'enabled':True, 'server_name':'localhost', 'insecure':True}
        if 'alpn' in ib['tls']: out['tls']['alpn'] = ib['tls']['alpn']
        if 'reality' in ib['tls']:
            out['tls'].pop('insecure')
            out['tls'].update(utls={'enabled':True,'fingerprint':'chrome'}, reality={'enabled':True,'public_key':public,'short_id':'abcd'})
    return out

def tcp(proxy, target, expected):
    r = subprocess.run(['curl','-fsS','--max-time','4','--noproxy','','--socks5-hostname',f'127.0.0.1:{proxy}',f'http://127.0.0.1:{target}/payload'], capture_output=True)
    if expected: assert r.returncode == 0 and r.stdout == b'x'*65536, r.stderr.decode()
    else: assert r.returncode != 0, 'unauthorized user was allowed'

def recvn(s, n):
    out = b''
    while len(out)<n:
        part=s.recv(n-len(out))
        if not part: raise RuntimeError('unexpected socks EOF')
        out+=part
    return out

def udp(proxy, target):
    with socket.create_connection(('127.0.0.1',proxy),timeout=4) as control, socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as data:
        control.sendall(b'\x05\x01\x00'); assert recvn(control,2)==b'\x05\x00'
        control.sendall(b'\x05\x03\x00\x01'+b'\0'*6)
        h=recvn(control,4); assert h[:2]==b'\x05\x00', h
        host=socket.inet_ntoa(recvn(control,4)) if h[3]==1 else socket.inet_ntop(socket.AF_INET6,recvn(control,16))
        port=struct.unpack('!H',recvn(control,2))[0]
        payload=b'udp-fixture'
        data.settimeout(4)
        data.sendto(b'\0\0\0\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',target)+payload,('127.0.0.1',port))
        assert data.recv(2048).endswith(payload)

with tempfile.TemporaryDirectory(prefix='sb-protocol-') as directory:
    d=pathlib.Path(directory); base=free_base()
    subprocess.run(['bash',str(ROOT/'tests/protocol-fixtures.sh'),str(d),str(base)],check=True,cwd=ROOT)
    (d/'payload').write_bytes(b'x'*65536)
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self,*args): pass
    http=http.server.ThreadingHTTPServer(('127.0.0.1',base+8),functools.partial(Quiet,directory=d))
    threading.Thread(target=http.serve_forever,daemon=True).start()
    echo=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);echo.bind(('127.0.0.1',base+8))
    def echo_loop():
        while True:
            try: data,addr=echo.recvfrom(65535);echo.sendto(data,addr)
            except OSError: return
    threading.Thread(target=echo_loop,daemon=True).start()
    allowed=json.loads((d/'allowed.json').read_text());public=(d/'public.key').read_text().strip()
    try:
        with process(['openssl','s_server','-accept',f'127.0.0.1:{base+10}','-cert',str(d/'cert.pem'),'-key',str(d/'key.pem'),'-tls1_3','-www'],d/'tls.log'):
            for state in ['allowed','disabled','unassigned']:
                with process([CORE,'run','-c',str(d/f'{state}.json')],d/'server.log'):
                    for proto,ib in zip(PROTOCOLS,allowed['inbounds']):
                        c={'inbounds':[{'type':'socks','tag':'client','listen':'127.0.0.1','listen_port':base+11}], 'outbounds':[outbound(ib,public)],'route':{'final':'proxy'}}
                        (d/'client.json').write_text(json.dumps(c))
                        with process([CORE,'run','-c',str(d/'client.json')],d/'client.log'):
                            tcp(base+11,base+8,state=='allowed')
                            if state=='allowed': udp(base+11,base+8)
                        print(f'PASS {proto}: {state}'+(' TCP+UDP' if state=='allowed' else ' denied'),flush=True)
    except Exception:
        for name in ['server.log','client.log','tls.log']:
            if (d/name).exists(): print(f'--- {name} ---\n'+(d/name).read_text()[-5000:],file=sys.stderr)
        raise
    finally:
        http.shutdown(); echo.close()
