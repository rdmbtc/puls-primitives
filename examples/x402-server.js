const express = require('express');
const { ethers } = require('ethers');

// Mock implementation of x402 payment flow for an agent economy
// This example shows how a server handles HTTP 402 requirements for premium API endpoints

const app = express();
const USDC_PRICE = "0.000005"; // Sub-cent nanopayment required

// Middleware to enforce x402 payment
const enforceX402 = async (req, res, next) => {
    const auth = req.headers.authorization;
    if (!auth || !auth.startsWith('L402 ')) {
        // Return 402 Payment Required
        res.status(402).set({
            'WWW-Authenticate': `L402 token="", invoice="<request-to-pay-${USDC_PRICE}-usdc>"`
        }).json({
            error: "Payment Required",
            price: USDC_PRICE,
            currency: "USDC",
            destination: "0xTreasuryAddress..."
        });
        return;
    }

    // Verify payment token (L402 verification)
    const token = auth.split(' ')[1];
    const isValid = await verifyPayment(token);
    
    if (!isValid) {
        return res.status(403).json({ error: "Invalid payment token" });
    }

    next();
};

async function verifyPayment(token) {
    // In production, verify the token represents a settled USDC transaction on Arc
    return true; 
}

app.get('/api/premium-data', enforceX402, (req, res) => {
    res.json({
        data: "Verified macro and crypto intel",
        agent_action: "Execute strategy"
    });
});

app.listen(3000, () => console.log('x402 Server running on port 3000'));
