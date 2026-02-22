import React, { useRef, useState, useEffect } from 'react';
import { Canvas, useFrame } from '@react-three/fiber';
import { OrbitControls, ContactShadows, useGLTF, useAnimations } from '@react-three/drei';
import './index.css';

function Mascot({ suspicionIndex }: { suspicionIndex: number }) {
    const groupRef = useRef<THREE.Group>(null);
    const { scene, animations } = useGLTF('/Tama.glb');
    const { actions } = useAnimations(animations, groupRef);

    // Color based on Suspicion
    // For a real model, we might tint a light or tint the materials if they exist
    let alertFactor = 1;
    if (suspicionIndex >= 9) { alertFactor = 4; }
    else if (suspicionIndex >= 6) { alertFactor = 2; }
    else if (suspicionIndex >= 3) { alertFactor = 1.5; }

    useEffect(() => {
        // Try to play animations based on score
        const actionNames = Object.keys(actions);
        if (actionNames.length === 0) return;

        // Try to guess animation names if we don't know them:
        // Or just play the first one and speed it up based on alert factor
        let selectedActionName = actionNames[0]; // fallback to first animation

        // You could map specific states to specific animations if you know their names in the .glb file.
        // E.g.
        // if (suspicionIndex >= 9 && actions['AttackAnim']) selectedActionName = 'AttackAnim';
        // else if (suspicionIndex >= 5 && actions['SuspiciousLook']) selectedActionName = 'SuspiciousLook';
        // else if (actions['Idle']) selectedActionName = 'Idle';

        const action = actions[selectedActionName];
        if (action) {
            action.reset().fadeIn(0.5).play();
            action.setEffectiveTimeScale(alertFactor);
            // Cleanup on state change
            return () => { action.fadeOut(0.5); };
        }
    }, [suspicionIndex, actions, alertFactor]);

    return (
        <group ref={groupRef} position={[0, -1, 0]}>
            <primitive object={scene} castShadow scale={1.2} />
        </group>
    );
}

// Preload the model so it doesn't pop in
useGLTF.preload('/Tama.glb');

function App() {
    const [debugOpen, setDebugOpen] = useState(false);
    const [tamaData, setTamaData] = useState({
        suspicion_index: 0,
        active_window: "Loading...",
        active_duration: 0,
        state: "CALM",
        alignment: 100,
        current_task: "..."
    });

    const wsRef = useRef<WebSocket | null>(null);
    const [sessionActive, setSessionActive] = useState(false);

    useEffect(() => {
        const connectWs = () => {
            const ws = new WebSocket('ws://localhost:8080');
            ws.onmessage = (event) => {
                try {
                    const data = JSON.parse(event.data);
                    setTamaData(data);
                    // Send to Electron Main Process for the Tray Menu
                    if ((window as any).require) {
                        const { ipcRenderer } = (window as any).require('electron');
                        ipcRenderer.send('tama-update', data);
                    }
                } catch (e) { }
            };
            ws.onclose = () => {
                setTimeout(connectWs, 2000); // Reconnect loop if python crashes
            };
            ws.onopen = () => {
                if (sessionActive) {
                    ws.send(JSON.stringify({ command: "START_SESSION" }));
                }
            };
            wsRef.current = ws;
        };
        connectWs();
    }, []);

    // Tama Movement CSS
    let opacity = 1.0;
    let yOffset = "100vh"; // Default: completely off-screen at the bottom

    if (!sessionActive) {
        yOffset = "10px"; // Lobby: centered
    } else if (tamaData.suspicion_index >= 6) {
        yOffset = "0px"; // Furious: fully popped up
    } else if (tamaData.suspicion_index >= 3) {
        yOffset = "35vh"; // Suspicious: head peeking out
    } else {
        yOffset = "100vh"; // Good behavior: sliding away
    }

    return (
        <div style={{ width: '100vw', height: '100vh', position: 'relative', overflow: 'hidden' }}>
            {/* 3D Canvas */}
            <div style={{
                position: 'absolute', width: '100%', height: '100%',
                opacity: opacity,
                transform: `translateY(${yOffset})`,
                transition: 'transform 1.0s cubic-bezier(0.25, 1, 0.5, 1)'
            }}>
                <Canvas shadows camera={{ position: [0, 2, 5], fov: 50 }} style={{ background: 'transparent' }}>
                    <ambientLight intensity={0.5} />
                    <directionalLight position={[5, 5, 5]} intensity={1.5} castShadow />
                    <pointLight position={[-5, 5, -5]} intensity={0.5} color="#00ffcc" />

                    <React.Suspense fallback={null}>
                        <Mascot suspicionIndex={tamaData.suspicion_index} />
                    </React.Suspense>

                    <ContactShadows position={[0, -1.2, 0]} opacity={0.4} scale={5} blur={2} far={2} />
                    <OrbitControls enableZoom={false} enablePan={false} />
                </Canvas>
            </div>

            {/* Debug Panel Toggle hidden in corner */}
            <div className="no-drag" style={{ position: 'absolute', top: 10, right: 10, zIndex: 999 }}>
                <button
                    onClick={() => setDebugOpen(!debugOpen)}
                    style={{ background: '#333', color: '#fff', border: '1px solid #444', borderRadius: '4px', padding: '5px 10px', cursor: 'pointer', fontSize: '10px' }}>
                    {debugOpen ? "Hide Debug 🙈" : "Show Debug 🛠️"}
                </button>
            </div>

            {/* Debug Panel GUI */}
            {debugOpen && (
                <div className="no-drag" style={{
                    position: 'absolute', top: 40, right: 10, background: 'rgba(0,0,0,0.85)', color: '#00ffcc', padding: '15px', borderRadius: '8px', border: '1px solid #444', fontSize: '12px', fontFamily: 'monospace', width: '250px', backdropFilter: 'blur(5px)', zIndex: 999, overflowWrap: 'break-word'
                }}>
                    <h3 style={{ margin: '0 0 10px 0', borderBottom: '1px solid #444', paddingBottom: '5px', color: '#fff' }}>🧠 Tama Brain Sync</h3>
                    <p style={{ margin: '5px 0' }}><b>AI State:</b> <span style={{ color: '#fff' }}>{tamaData.state}</span></p>
                    <p style={{ margin: '5px 0' }}><b>Suspicion (S):</b> <span style={{ color: '#fff' }}>{tamaData.suspicion_index}/10</span></p>
                    <p style={{ margin: '5px 0' }}><b>Alignment:</b> <span style={{ color: tamaData.alignment < 50 ? '#ff9500' : '#00ffcc' }}>{tamaData.alignment}%</span></p>
                    <p style={{ margin: '5px 0' }}><b>Task:</b> <span style={{ color: '#aaa' }}>{tamaData.current_task}</span></p>
                    <p style={{ margin: '5px 0' }}><b>Window Active:</b> <br /><span style={{ color: '#aaa' }}>{tamaData.active_window}</span></p>
                    <p style={{ margin: '5px 0' }}><b>Duration:</b> <span style={{ color: '#fff' }}>{tamaData.active_duration}s</span></p>
                </div>
            )}

            {/* Floating UI overlay */}
            <div className="no-drag" style={{
                position: 'absolute', bottom: '20px', width: '100%', textAlign: 'center', pointerEvents: 'none', transition: 'all 0.5s'
            }}>
                {!sessionActive ? (
                    <button
                        onClick={() => {
                            setSessionActive(true);
                            if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
                                wsRef.current.send(JSON.stringify({ command: "START_SESSION" }));
                            }
                        }}
                        style={{
                            background: '#ff003c', color: '#fff', border: 'none', padding: '15px 30px',
                            borderRadius: '30px', fontWeight: 'bold', fontSize: '18px', cursor: 'pointer',
                            pointerEvents: 'auto', boxShadow: '0px 0px 20px rgba(255, 0, 60, 0.5)',
                            transition: 'all 0.2s', textTransform: 'uppercase'
                        }}
                        onMouseOver={(e) => (e.currentTarget.style.transform = 'scale(1.05)')}
                        onMouseOut={(e) => (e.currentTarget.style.transform = 'scale(1)')}
                    >
                        ⚡ Start Deep Work
                    </button>
                ) : (
                    <div style={{
                        display: 'inline-block', background: 'rgba(0,0,0,0.6)', padding: '8px 16px',
                        borderRadius: '20px', backdropFilter: 'blur(5px)', fontWeight: 'bold',
                        letterSpacing: '1px', fontSize: '14px', pointerEvents: 'auto', opacity: opacity,
                        transition: 'opacity 0.5s'
                    }}>
                        ● TAMA ACTIVE
                    </div>
                )}
            </div>
        </div>
    );
}

export default App;
