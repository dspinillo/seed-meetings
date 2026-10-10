#!/usr/bin/env python3
"""Teste ponta a ponta do MCP real, via stdio, com arquivos inteiramente fictícios."""
import base64
import datetime
import io
import json
import math
import os
import shutil
import uuid
import select
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import wave

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else '.build/release/seed-mcp').resolve())
with tempfile.TemporaryDirectory(prefix='seed-mcp-test-') as directory:
    root = Path(directory) / 'data'
    folder = root / '20990101-100000'
    folder.mkdir(parents=True)
    meta = {'title': 'Projeto Aurora fictício', 'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'), 'durationSeconds': 3, 'status': 'ready'}
    (folder / 'meta.json').write_text(json.dumps(meta))
    transcript = '[00:01] Ana: orçamento aprovado.\n' * 10000
    (folder / 'transcript.md').write_text(transcript)
    (folder / 'resumo.md').write_text('## TL;DR\nProjeto Aurora aprovado.')
    (folder / 'notas.md').write_text('Revisar orçamento.')
    (folder / 'classificacao.json').write_text(json.dumps({'temperatura': 'tensa', 'temperatura_motivo': 'Prazo apertado.', 'evidencias': [{'momento': '00:01', 'trecho': 'orçamento aprovado'}], 'ferramentas': ['Zendesk'], 'temas': ['orçamento'], 'flags': ['risco_de_prazo']}))
    (root / 'topicos.json').write_text(json.dumps([{'id': 'T1', 'name': 'Aurora', 'description': 'Projeto fictício', 'meetingIDs': [folder.name, 'inexistente'], 'createdAt': meta['startedAt'], 'summary': 'Resumo do tópico.'}]))
    with wave.open(str(folder / 'mic.wav'), 'wb') as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(48000)
        samples = bytearray()
        for i in range(3 * 48000):
            value = int(12000 * math.sin(i * 2 * math.pi * 440 / 48000))
            samples.extend(struct.pack('<hh', value, value))
        wav.writeframes(samples)
    # CAF também precisa funcionar, pois é o formato das novas gravações.
    subprocess.run(['/usr/bin/afconvert', '-f', 'caff', '-d', 'LEI16', str(folder / 'mic.wav'), str(folder / 'sistema.caf')], check=True)
    outside = Path(directory) / 'outside'
    outside.mkdir()
    (outside / 'meta.json').write_text(json.dumps({**meta, 'title': 'NAO_EXPOR'}))
    (outside / 'secret.md').write_text('NAO_EXPOR')
    (root / 'outside-link').symlink_to(outside, target_is_directory=True)
    env = {**os.environ, 'SEED_DATA_DIR': str(root)}
    with tempfile.TemporaryFile() as err:
        process = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True, env=env)
        counter = 0
        def rpc(method, params=None):
            global counter
            counter += 1
            message = {'jsonrpc': '2.0', 'id': counter, 'method': method}
            if params is not None:
                message['params'] = params
            process.stdin.write(json.dumps(message) + '\n')
            process.stdin.flush()
            assert select.select([process.stdout], [], [], 20)[0], 'MCP não respondeu em 20s'
            response = json.loads(process.stdout.readline())
            assert response['id'] == counter, response
            return response
        def call(name, **args):
            return rpc('tools/call', {'name': name, 'arguments': args})
        def data(name, **args):
            response = call(name, **args)
            assert 'error' not in response and not response['result'].get('isError'), response
            return response['result']['structuredContent']
        try:
            init = rpc('initialize', {'protocolVersion': 'unknown', 'capabilities': {}, 'clientInfo': {'name': 'seed-test', 'version': '1'}})
            assert init['result']['protocolVersion'] == '2025-11-25'
            process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            process.stdin.flush()
            assert rpc('ping')['result'] == {}
            names = {tool['name'] for tool in rpc('tools/list')['result']['tools']}
            assert names == {'list_meetings', 'get_meeting', 'get_summary', 'get_transcript', 'search_meetings', 'list_audio', 'get_audio',
                             'semantic_search', 'list_topics', 'get_topic'}
            detail = data('get_meeting', id=folder.name)
            assert detail['classification']['temperatura'] == 'tensa' and detail['classification']['ferramentas'] == ['Zendesk']
            assert detail['topics'] == [{'topic_id': 'T1', 'name': 'Aurora'}]
            assert data('search_meetings', query='orçamento', temperature='tensa', flag='risco_de_prazo')['total'] == 1
            assert data('search_meetings', query='orçamento', temperature='tranquila')['total'] == 0
            assert data('list_meetings', flag='escalonamento')['total'] == 0
            assert call('search_meetings', query='orçamento', temperature='quente')['error']['code'] == -32602
            assert data('list_topics')['topics'] == [{'topic_id': 'T1', 'name': 'Aurora', 'description': 'Projeto fictício', 'meeting_count': 2}]
            topic = data('get_topic', topic_id='T1')
            assert [m['id'] for m in topic['meetings']] == [folder.name] and topic['summary'] == 'Resumo do tópico.'
            assert call('get_topic', topic_id='nope')['result']['isError']
            # busca semântica vem desligada por padrão: erro claro, não resultado vazio
            assert call('semantic_search', query='orçamento')['result']['isError']
            listed = data('list_meetings')
            assert listed['total'] == 1 and listed['meetings'][0]['id'] == folder.name
            assert data('list_meetings', offset=5)['meetings'] == []
            assert data('get_meeting', id=folder.name)['notes'] == 'Revisar orçamento.'
            assert 'Aurora' in data('get_summary', id=folder.name)['text']
            assert data('search_meetings', query='ORCAMENTO')['total'] == 1
            pieces = []
            offset = 0
            while offset is not None:
                page = data('get_transcript', id=folder.name, offset=offset, limit=17000)
                pieces.append(page['text'])
                offset = page['next_offset']
            assert ''.join(pieces) == transcript
            tracks = data('list_audio', id=folder.name)['tracks']
            assert all(t['available'] and abs(t['duration_seconds'] - 3) < .01 for t in tracks)
            for track in ['mic', 'system']:
                result = call('get_audio', id=folder.name, track=track, start_seconds=1, duration_seconds=1)['result']
                block = next(c for c in result['content'] if c['type'] == 'audio')
                assert block['mimeType'] == 'audio/wav'
                with wave.open(io.BytesIO(base64.b64decode(block['data']))) as wav:
                    assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, 16000)
                    assert 15000 <= wav.getnframes() <= 16000
                    assert any(wav.readframes(wav.getnframes()))
            # Fim da trilha: retorna somente os frames disponíveis.
            result = call('get_audio', id=folder.name, track='mic', start_seconds=2.5, duration_seconds=30)['result']
            blob = next(c['data'] for c in result['content'] if c['type'] == 'audio')
            with wave.open(io.BytesIO(base64.b64decode(blob))) as wav:
                assert 7000 <= wav.getnframes() <= 8000
            for name, args in [('list_meetings', {'limit': -1}), ('list_meetings', {'limit': True}),
                               ('list_meetings', {'limit': 1.5}), ('get_audio', {'id': folder.name, 'track': 'other'}),
                               ('get_audio', {'id': folder.name, 'track': 'mic', 'duration_seconds': 31}),
                               ('get_transcript', {'id': folder.name, 'offset': -1})]:
                assert call(name, **args)['error']['code'] == -32602
            assert call('get_audio', id=folder.name, track='mic', start_seconds=20)['result']['isError']
            assert call('get_summary', id='../outside')['result']['isError']
            (folder / 'resumo.md').unlink()
            (folder / 'resumo.md').symlink_to(outside / 'secret.md')
            assert call('get_summary', id=folder.name)['result']['isError']
            assert 'NAO_EXPOR' not in json.dumps(data('get_meeting', id=folder.name))
            (folder / 'mic.wav').unlink()
            assert not data('list_audio', id=folder.name)['tracks'][0]['available']
            assert call('get_audio', id=folder.name, track='mic')['result']['isError']
            (folder / 'mic.wav').symlink_to(folder / 'sistema.caf')
            # Symlink para fora da pasta é recusado, mesmo se for um áudio válido.
            (folder / 'mic.wav').unlink()
            (folder / 'mic.wav').symlink_to(outside / 'secret.md')
            assert call('get_audio', id=folder.name, track='mic')['result']['isError']
            process.stdin.write('invalid json\n')
            process.stdin.flush()
            assert json.loads(process.stdout.readline())['error']['code'] == -32700
            assert rpc('unknown')['error']['code'] == -32601
            assert rpc('ping')['result'] == {}
            print('OK: MCP stdio, 10 ferramentas, classificação, tópicos, paginação integral, WAV/CAF, áudio decodificável, erros e isolamento de caminhos.')
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            assert process.returncode == 0

    if os.environ.get('SEED_MCP_AGENT_TEST') == '1':
        # Somente uma configuração efêmera. Não registra MCP na conta do usuário.
        (folder / 'resumo.md').unlink()
        marker = 'AURORA-' + uuid.uuid4().hex[:10]
        (folder / 'resumo.md').write_text('## TL;DR\nCódigo de referência: ' + marker)
        result_file = Path(directory) / 'answer.md'
        command = [shutil.which('codex') or 'codex', 'exec', '--ignore-user-config', '--skip-git-repo-check',
                   '--ephemeral', '--sandbox', 'read-only', '--model', 'gpt-5.6-luna',
                   '-c', 'mcp_servers.seed.command=' + json.dumps(binary),
                   '-c', 'mcp_servers.seed.env.SEED_DATA_DIR=' + json.dumps(str(root)),
                   '--output-last-message', str(result_file),
                   'Use somente as ferramentas MCP do servidor seed, sem comandos de shell. '
                   'Liste as reuniões, leia o resumo e uma página de transcrição da primeira e liste suas trilhas de áudio. '
                   'Informe o código de referência do resumo, o nome citado na transcrição e a duração da trilha system. '
                   'Não precisa ouvir o áudio.']
        run = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=180)
        assert run.returncode == 0, run.stderr[-1500:]
        answer = result_file.read_text()
        assert marker in answer and 'Ana' in answer and '3' in answer, answer
        print('OK: agente Codex consumiu resumo, transcrição e metadados de áudio via MCP efêmero.')
