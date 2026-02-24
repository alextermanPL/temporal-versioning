#!/bin/bash

echo "==> Step 1: Initiate payment"
curl -s -X POST http://localhost:9090/payments \
  -H "Content-Type: application/json" \
  -d '{
    "paymentId": "1",
    "amount": 100.00,
    "currency": "EUR",
    "debtorAccount": "LT001",
    "creditorAccount": "LT002"
  }' | jq .

echo ""
echo "==> Step 2: Send reservation signal (bank callback)"
curl -s -X POST http://localhost:9090/payments/1/reservation-result \
  -H "Content-Type: application/json" \
  -d '{"success": true}' | jq .
