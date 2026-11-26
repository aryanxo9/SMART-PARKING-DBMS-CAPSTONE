// =====================================================================
// CO4 NoSQL extension : real-time gate / sensor event log in MongoDB
// Run:  mongosh "mongodb://localhost:27017" mongodb/gate_events.js
//       (or paste a MongoDB Atlas connection string for the cloud option)
//
// WHY MONGODB HERE?  Gate cameras, ANPR units and slot sensors emit events whose
// fields differ by device (confidence score, image URL, battery %, barrier error ...).
// Forcing them into one relational table gives many NULL columns or constant ALTERs.
// Core transactional data (reservations, payments, violations) stays in MySQL because
// it needs ACID transactions, foreign keys and row locks.
// =====================================================================
const sdb = db.getSiblingDB("smart_parking_events");
sdb.gate_events.drop();

// ---------- 1. CREATE : insert flexible documents ----------------------
sdb.gate_events.insertMany([
  { ts: new Date(), type: "ENTRY", gate: "G1", zone: "Zone A", slot_id: 3,
    vehicle_reg: "DL04CA1021", source: "ANPR",
    anpr: { confidence: 0.97, plate_image: "img/2026/11/16/0001.jpg", camera: "CAM-G1-IN" } },
  { ts: new Date(), type: "EXIT", gate: "G1", zone: "Zone A", slot_id: 3,
    vehicle_reg: "DL04CA1021", source: "ANPR", fee: 40,
    anpr: { confidence: 0.94, camera: "CAM-G1-OUT" } },
  { ts: new Date(), type: "SENSOR_FAULT", zone: "Zone B", slot_id: 17, source: "SLOT_SENSOR",
    sensor: { id: "S-017", battery_pct: 8, firmware: "2.1.4" }, tags: ["maintenance", "battery"] },
  { ts: new Date(), type: "BARRIER_ERROR", gate: "G2", source: "BARRIER",
    error: { code: "E42", message: "Arm stuck", retries: 3 } }
]);

// bulk-generate 300 synthetic events over the last 3 days
const zones = ["Zone A", "Zone B", "Zone C", "Zone D", "Zone E"];
const bulk = [];
for (let i = 0; i < 300; i++) {
  const t = new Date(Date.now() - Math.floor(Math.random() * 3 * 24 * 3600 * 1000));
  const type = Math.random() < 0.5 ? "ENTRY" : "EXIT";
  bulk.push({
    ts: t, type: type, gate: "G" + (1 + (i % 3)),
    zone: zones[i % 5], slot_id: 1 + (i % 60),
    vehicle_reg: "DL" + String(1 + (i % 14)).padStart(2, "0") + "CA" + (1000 + (i % 70) * 7),
    source: "ANPR",
    anpr: { confidence: +(0.80 + Math.random() * 0.2).toFixed(2) },
    dwell_min: type === "EXIT" ? 20 + Math.floor(Math.random() * 240) : null
  });
}
sdb.gate_events.insertMany(bulk);
print("documents inserted: " + sdb.gate_events.countDocuments());

// ---------- 2. INDEXES -------------------------------------------------
sdb.gate_events.createIndex({ ts: -1 });                        // time-range queries
sdb.gate_events.createIndex({ vehicle_reg: 1, ts: -1 });        // history of one vehicle
sdb.gate_events.createIndex({ type: 1, zone: 1 });              // dashboards
sdb.gate_events.createIndex({ ts: 1 }, { expireAfterSeconds: 90 * 24 * 3600, name: "ttl_90_days" }); // auto-purge

// ---------- 3. READ ----------------------------------------------------
printjson(sdb.gate_events.find({ type: "SENSOR_FAULT" }).toArray());
printjson(sdb.gate_events.find({ "anpr.confidence": { $lt: 0.85 } }, { vehicle_reg: 1, "anpr.confidence": 1 }).limit(5).toArray());
printjson(sdb.gate_events.find({ vehicle_reg: "DL04CA1021" }).sort({ ts: -1 }).limit(3).toArray());

// ---------- 4. UPDATE --------------------------------------------------
sdb.gate_events.updateOne({ type: "SENSOR_FAULT", slot_id: 17 },
                         { $set: { resolved: true, resolved_at: new Date() }, $push: { tags: "replaced" } });
sdb.gate_events.updateMany({ type: "ENTRY", "anpr.confidence": { $lt: 0.85 } },
                          { $set: { needs_review: true } });

// ---------- 5. DELETE --------------------------------------------------
sdb.gate_events.deleteMany({ type: "BARRIER_ERROR", "error.retries": { $gte: 3 }, resolved: { $exists: false } });

// ---------- 6. AGGREGATION PIPELINES --------------------------------------
// 6a  Events per hour of day and type  (peak hours -- compare with SQL query Q5)
printjson(sdb.gate_events.aggregate([
  { $match: { type: { $in: ["ENTRY", "EXIT"] } } },
  { $group: { _id: { hour: { $hour: "$ts" }, type: "$type" }, events: { $sum: 1 } } },
  { $sort: { events: -1 } },
  { $limit: 5 }
]).toArray());

// 6b  Average dwell time and ANPR confidence per zone
printjson(sdb.gate_events.aggregate([
  { $match: { type: "EXIT", dwell_min: { $ne: null } } },
  { $group: { _id: "$zone", exits: { $sum: 1 }, avg_dwell_min: { $avg: "$dwell_min" },
              avg_confidence: { $avg: "$anpr.confidence" } } },
  { $project: { zone: "$_id", _id: 0, exits: 1,
                avg_dwell_min: { $round: ["$avg_dwell_min", 1] },
                avg_confidence: { $round: ["$avg_confidence", 3] } } },
  { $sort: { avg_dwell_min: -1 } }
]).toArray());

// 6c  Vehicles with the most gate events (candidates for ANPR misreads / loitering)
printjson(sdb.gate_events.aggregate([
  { $group: { _id: "$vehicle_reg", events: { $sum: 1 }, last_seen: { $max: "$ts" } } },
  { $match: { _id: { $ne: null } } },
  { $sort: { events: -1 } }, { $limit: 5 }
]).toArray());

// ---------- 7. EXPLAIN (index justification) -----------------------------
printjson(sdb.gate_events.find({ vehicle_reg: "DL04CA1021" }).sort({ ts: -1 }).explain("executionStats").executionStats);

// ---------- 8. SQL <-> NoSQL link ----------------------------------------------
// vehicle_reg is the join key to MySQL vehicle.reg_no; app/parking_app.py shows an
// application-level join (look up the vehicle in MySQL, fetch its events from MongoDB).
