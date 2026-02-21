import React, { useRef, useState } from 'react';
import { Canvas, useFrame } from '@react-three/fiber';
import { OrbitControls, ContactShadows } from '@react-three/drei';
import './index.css';

// A simple floating companion for now!
function Mascot() {
    const meshRef = useRef<THREE.Mesh>(null);

    // Floating animation
    useFrame((state) => {
        if (meshRef.current) {
            meshRef.current.position.y = Math.sin(state.clock.elapsedTime * 2) * 0.1;
            meshRef.current.rotation.y = Math.sin(state.clock.elapsedTime * 0.5) * 0.2;
        }
    });

    return (
        <group>
            <mesh ref={meshRef} position={[0, 0, 0]} castShadow>
                <boxGeometry args={[1.5, 1.5, 1.5]} />
                <meshPhysicalMaterial
                    color="#ff3b30"
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
    return (
        <div style={{ width: '100vw', height: '100vh', position: 'relative' }}>
            {/* 3D Canvas */}
            <Canvas shadows camera={{ position: [0, 2, 5], fov: 50 }} style={{ background: 'transparent' }}>
                <ambientLight intensity={0.5} />
                <directionalLight position={[5, 5, 5]} intensity={1.5} castShadow />
                <pointLight position={[-5, 5, -5]} intensity={0.5} color="#00ffcc" />

                <Mascot />

                {/* Soft shadow projected underneath */}
                <ContactShadows position={[0, -1.2, 0]} opacity={0.4} scale={5} blur={2} far={2} />

                {/* Allow users to rotate Tama (if we enable drag cursor) */}
                <OrbitControls enableZoom={false} enablePan={false} />
            </Canvas>

            {/* Floating UI overlay */}
            <div
                className="no-drag"
                style={{
                    position: 'absolute',
                    bottom: '20px',
                    width: '100%',
                    textAlign: 'center',
                    pointerEvents: 'none',
                }}
            >
                <div style={{
                    display: 'inline-block',
                    background: 'rgba(0,0,0,0.6)',
                    padding: '8px 16px',
                    borderRadius: '20px',
                    backdropFilter: 'blur(5px)',
                    fontWeight: 'bold',
                    letterSpacing: '1px',
                    fontSize: '14px',
                    pointerEvents: 'auto',
                    cursor: 'pointer'
                }}>
                    ● TAMA ACTIVE
                </div>
            </div>
        </div>
    );
}

export default App;
