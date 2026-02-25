import asyncio
import websockets
import json

async def send():
    async with websockets.connect('ws://localhost:8080') as ws:
        await ws.send(json.dumps({'command': 'START_SESSION'}))

asyncio.run(send())
