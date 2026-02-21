import React, { useRef, useState, useEffect } from 'react';
import { Canvas, useFrame } from '@react-three/fiber';
import { OrbitControls, ContactShadows } from '@react-three/drei';
import './index.css';

function Mascot({ suspicionIndex }: { suspicionIndex: number }) {
    const meshRef = useRef<THREE.Mesh>(null);

    // Color based on Suspicion
    // 0-2 (Green/Calm), 3-5 (Yellow/Curious), 6-8 (Orange/Suspicious), 9-10 (Red/Raid)
    let color = "#00ffcc";
    let alertFactor = 1;
    if (suspicionIndex >= 9) { color = "#ff3b30"; alertFactor = 3; }
    else if (suspicionIndex >= 6) { color = "#ff9500"; alertFactor = 2; }
    else if (suspicionIndex >= 3) { color = "#ffcc00"; alertFactor = 1.5; }

    useFrame((state) => {
        if (meshRef.current) {
            meshRef.current.position.y = Math.sin(state.clock.elapsedTime * 2 * alertFactor) * (0.1 * alertFactor);
            meshRef.current.rotation.y = Math.sin(state.clock.elapsedTime * 0.5) * 0.2;
        }
    });

    return (
        <group>
            <mesh ref={meshRef} position={[0, 0, 0]} castShadow>
                <boxGeometry args={[1.5, 1.5, 1.5]} />
                <meshPhysicalMaterial
                    color={color}
                    roughness={0.2}
                    metalness={0.8}
                    clearcoat={1}
                />
            </mesh>
            {/* Eyes */}
            <mesh position={[-0.4, 0.2, 0.76]}>
                <sphereGeometry args={[0.15, 32, 32]} />
                <meshBasicMaterial color="white" />
            </mesh>
            <mesh position={[0.4, 0.2, 0.76]}>
                <sphereGeometry args={[0.15, 32, 32]} />
                <meshBasicMaterial color="white" />
            </mesh>
            {/* Pupils */}
            <mesh position={[-0.4, 0.2, 0.88]}>
                <sphereGeometry args={[0.07, 32, 32]} />
                <meshBasicMaterial color="black" />
            </mesh>
            <mesh position={[0.4, 0.2, 0.88]}>
                <sphereGeometry args={[0.07, 32, 32]} />
                <meshBasicMaterial color="black" />
            </mesh>
        </group>
    );
}

function App() {
    const [debugOpen, setDebugOpen] = useState(false);
    const [tamaData, setTamaData] = useState({
        suspicion_index: 0,
        active_window: "Loading...",
        active_duration: 0,
        state: "CALM"
    });

    useEffect(() => {
        const connectWs = () => {
            const ws = new WebSocket('ws://localhost:8080');
            ws.onmessage = (event) => {
                try {
                    const data = JSON.parse(event.data);
                    setTamaData(data);
                } catch (e) { }
            };
            ws.onclose = () => {
                setTimeout(connectWs, 2000); // Reconnect loop if python crashes
            };
        };
        connectWs();
    }, []);

    // Tama CSS State Visibility
    // < 3: complete invisibility
    // 3 to 5: Semi-transparent, drops slightly
    // > 5: Fully visible and opaque!
    let opacity = 0;
    let yOffset = "100px";
    if (tamaData.suspicion_index >= 6) { opacity = 1; yOffset = "0px"; }
    else if (tamaData.suspicion_index >= 3) { opacity = 0.5; yOffset = "50px"; }

    return (
        <div style={{ width: '100vw', height: '100vh', position: 'relative' }}>
            {/* 3D Canvas */}
            <div style={{
                position: 'absolute', width: '100%', height: '100%',
                opacity: opacity,
                transform: `translateY(${yOffset})`,
                transition: 'all 0.5s cubic-bezier(0.25, 1, 0.5, 1)'
            }}>
                <Canvas shadows camera={{ position: [0, 2, 5], fov: 50 }} style={{ background: 'transparent' }}>
                    <ambientLight intensity={0.5} />
                    <directionalLight position={[5, 5, 5]} intensity={1.5} castShadow />
                    <pointLight position={[-5, 5, -5]} intensity={0.5} color="#00ffcc" />

                    <Mascot suspicionIndex={tamaData.suspicion_index} />

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
                    <p style={{ margin: '5px 0' }}><b>Window Active:</b> <br /><span style={{ color: '#aaa' }}>{tamaData.active_window}</span></p>
                    <p style={{ margin: '5px 0' }}><b>Duration:</b> <span style={{ color: '#fff' }}>{tamaData.active_duration}s</span></p>
                </div>
            )}

            {/* Floating UI overlay */}
            <div className="no-drag" style={{
                position: 'absolute', bottom: '20px', width: '100%', textAlign: 'center', pointerEvents: 'none', opacity: opacity, transition: 'opacity 0.5s'
            }}>
                <div style={{
                    display: 'inline-block', background: 'rgba(0,0,0,0.6)', padding: '8px 16px', borderRadius: '20px', backdropFilter: 'blur(5px)', fontWeight: 'bold', letterSpacing: '1px', fontSize: '14px', pointerEvents: 'auto', cursor: 'pointer'
                }}>
                    ● TAMA ACTIVE
                </div>
            </div>
        </div>
    );
}

export default App;
