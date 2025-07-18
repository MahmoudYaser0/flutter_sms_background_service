const app = require('express')();
const server = require('http').createServer(app);
const io = require('socket.io')(server);
const port = process.env.PORT || 8080;

const express = require('express');
const http = require('http');
const path = require('path');

// Store active device connections
const deviceConnections = new Map();

// Serve static files
app.use(express.static(path.join(__dirname, 'public')));

// Simple route
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

io.on('connection', async (socket) => {
    console.log('New connection attempt, socket ID:', socket.id);
    
    // Get device ID from query parameters
    const deviceId = socket.handshake.query.deviceId;
    
    if (!deviceId) {
        console.log('Connection rejected: No device ID provided');
        socket.disconnect(true);
        return;
    }
    
    // Check if this device already has an active connection
    if (deviceConnections.has(deviceId)) {
        const existingSocket = deviceConnections.get(deviceId);
        
        // If the existing socket is still connected, disconnect the new one
        if (io.sockets.sockets.has(existingSocket)) {
            console.log(`Device ${deviceId} already connected. Rejecting new connection.`);
            socket.disconnect(true);
            return;
        }
    }
    
    // Store the new connection
    deviceConnections.set(deviceId, socket.id);
    console.log(`Device ${deviceId} connected with socket ID ${socket.id}`);
    
    // Handle device registration
    socket.on('register', (data) => {
        if (data.deviceId && data.deviceId === deviceId) {
            console.log(`Device ${deviceId} registered successfully`);
            // You can store additional device info here if needed
        }
    });

    // Handle new messages
    socket.on('message', (msg) => {
        console.log(`Message from ${deviceId}:`, msg);
        // Broadcast the message to all connected clients
        io.emit('message', msg);
    });
    
    // Handle heartbeat messages
    socket.on('heartbeat', (data) => {
        console.log(`Heartbeat from ${deviceId} at ${data.timestamp}`);
        // You can respond to heartbeats if needed
        socket.emit('heartbeat_ack', { received: true, timestamp: new Date().toISOString() });
    });

    socket.on('disconnect', function () {
        console.log(`Device ${deviceId} disconnected`);
        // Only remove from the map if this socket ID matches the stored one
        if (deviceConnections.get(deviceId) === socket.id) {
            deviceConnections.delete(deviceId);
        }
    });

    // Send periodic messages to this device
    let i = 0;
    const intervalId = setInterval(() => {
        if (socket.connected) {
            socket.emit('message', `Server message to ${deviceId}: ${i}`);
            i++;
        } else {
            clearInterval(intervalId);
        }
    }, 7200000); // Two hours
    
    // Clean up interval on disconnect
    socket.on('disconnect', () => {
        clearInterval(intervalId);
    });
});

server.listen(port, function () {
    console.log(`Listening on port ${port}`);
});

