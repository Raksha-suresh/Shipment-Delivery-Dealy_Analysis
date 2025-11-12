select *from orders;
select* from routes;
select* from`shipment track`;

------ Backup table -----
CREATE TABLE Orders_backup AS SELECT * FROM Orders;
CREATE TABLE Routes_backup  AS SELECT * FROM Routes;

---- Finding duplicates -----
SELECT Order_ID, COUNT(*) AS cnt
FROM Orders
GROUP BY Order_ID
HAVING cnt > 1;

---- Date format in YYYY-MM-DD format -----
update orders 
set Order_Date = date_format( STR_TO_DATE( Order_Date, '%d-%m-%Y'), '%Y-%m-%d');
update orders 
set Expected_Delivery_Date = date_format( STR_TO_DATE( Expected_Delivery_Date, '%d-%m-%Y'), '%Y-%m-%d');
update orders 
set Actual_Delivery_Date = date_format( STR_TO_DATE( Actual_Delivery_Date, '%d-%m-%Y'), '%Y-%m-%d');

----- Adding & calculating the delay in delivery ------
ALTER TABLE Orders ADD COLUMN Delivery_Delay_Days INT;
UPDATE Orders
SET Delivery_Delay_Days = DATEDIFF(Actual_Delivery_Date, Expected_Delivery_Date);

----- Top 10 delayed routes by average delay ----
SELECT r.Route_ID, r.Start_Location, r.End_Location,
       ROUND(AVG(o.Delivery_Delay_Days),2) AS avg_delay_days,
       COUNT(*) AS shipments
FROM Orders o
JOIN Routes r ON o.Route_ID = r.Route_ID
GROUP BY r.Route_ID, r.Start_Location, r.End_Location
ORDER BY avg_delay_days DESC
LIMIT 10;

-----  Rank orders by delay within each warehouse ----
SELECT Order_ID, Warehouse_ID, Delivery_Delay_Days,
       RANK() OVER (PARTITION BY Warehouse_ID ORDER BY Delivery_Delay_Days DESC) AS delay_rank_warehouse
FROM Orders;

----- Average delivery time, distance_time_ratio, Average traffic delay ----
WITH route_stats AS (
  SELECT r.Route_ID,
         ROUND(AVG(DATEDIFF(o.Actual_Delivery_Date, o.Order_Date)),2) AS avg_delivery_days,
         ROUND(AVG(r.Traffic_Delay_Min),2) AS avg_traffic_delay_min,
         r.Distance_KM,
         r.Average_Travel_Time_Min,
         CASE WHEN r.Average_Travel_Time_Min IS NULL OR r.Average_Travel_Time_Min = 0
              THEN NULL
              ELSE ROUND(r.Distance_KM / r.Average_Travel_Time_Min,4)
         END AS distance_to_time_ratio
  FROM Routes r
  LEFT JOIN Orders o ON o.Route_ID = r.Route_ID
  GROUP BY r.Route_ID, r.Average_Travel_Time_Min, r.Distance_KM
)
SELECT * FROM route_stats;

------ 3 worst efficiency ratio -----
select
Route_ID, Distance_KM, Average_Travel_Time_Min, 
(Distance_KM / nullif(Average_Travel_Time_Min,0)) AS Distance_time_ratio
from routes
order by Distance_time_ratio asc
limit 3;

----- Routes with> 20% delayed shipments ----
SELECT r.Route_ID,
       COUNT(*) AS total_shipments,
       SUM(CASE WHEN o.Delivery_Delay_Days > 0 THEN 1 ELSE 0 END) AS delayed_shipments,
       ROUND(100 * SUM(CASE WHEN o.Delivery_Delay_Days > 0 THEN 1 ELSE 0 END) / COUNT(*),2) AS delayed_pct
FROM Orders o
JOIN Routes r ON o.Route_ID = r.Route_ID
GROUP BY r.Route_ID
HAVING delayed_pct > 20;

----- Task 4: Top 3 warehouse by average processing time ----
SELECT w.Warehouse_ID, Location,
       ROUND(AVG(TIMESTAMPDIFF(minute, w.Processing_Time_Min, w.Dispatch_Time))/60,2) AS avg_processing_hours
FROM orders o 
JOIN Warehouses w ON o.Warehouse_ID = w.Warehouse_ID
WHERE w.Processing_Time_Min IS NOT NULL 
  AND w.Dispatch_Time IS NOT NULL
GROUP BY w.Warehouse_ID, Location
ORDER BY avg_processing_hours DESC
LIMIT 3;

----- Total vs delayed shipments for each warehouse ------
SELECT w.Warehouse_ID, Location,
       COUNT(*) AS total_shipments,
       SUM(CASE WHEN o.Delivery_Delay_Days > 0 THEN 1 ELSE 0 END) AS delayed_shipments,
       ROUND(100 * SUM(CASE WHEN o.Delivery_Delay_Days > 0 THEN 1 ELSE 0 END) / COUNT(*),2) AS delayed_pct
FROM Orders o
JOIN Warehouses w ON o.Warehouse_ID = w.Warehouse_ID
GROUP BY w.Warehouse_ID, Location
ORDER BY delayed_pct DESC;

------- CTEs to find bottleneck warehouses ------
WITH warehouse_avg AS (
  SELECT Warehouse_ID, 
  AVG(TIMESTAMPDIFF(MINUTE, Processing_Time_Min, Dispatch_Time)) AS avg_proc_min
  FROM warehouses
  GROUP BY Warehouse_ID
),
global_avg AS (
  SELECT AVG(avg_proc_min) AS global_avg_proc_min FROM warehouse_avg
)
SELECT wa.Warehouse_ID, wa.avg_proc_min, ga.global_avg_proc_min
FROM warehouse_avg wa CROSS JOIN global_avg ga
WHERE wa.avg_proc_min > ga.global_avg_proc_min
ORDER BY wa.avg_proc_min DESC;

------ ---- Rank warehouse by one-time delivery % -----
SELECT w.Warehouse_ID, w.Location,
       ROUND(100 * SUM(CASE WHEN Delivery_Delay_Days = 0 THEN 1 ELSE 0 END) / COUNT(*),2) AS on_time_pct,
       RANK() OVER (ORDER BY ROUND(100 * SUM(CASE WHEN Delivery_Delay_Days = 0 THEN 1 ELSE 0 END) / COUNT(*),2) DESC) AS on_time_rank
FROM Orders o
JOIN Warehouses w  ON o.Warehouse_ID = w.Warehouse_ID
GROUP BY w.Warehouse_ID, w.Location ;

------ Task 5: Delivery agent performance -----
SELECT d.Agent_ID, d.Route_ID,
       ROUND(100 * SUM(CASE WHEN Delivery_Delay_Days = 0 THEN 1 ELSE 0 END) / COUNT(*),2) AS on_time_pct,
       RANK() OVER (PARTITION BY Route_ID ORDER BY ROUND(100 * SUM(CASE WHEN Delivery_Delay_Days = 0 THEN 1 ELSE 0 END) / COUNT(*),2) DESC) AS agent_rank_within_route
FROM orders o
JOIN deliveryagents d ON d.Route_ID = o.Route_ID
GROUP BY d.Agent_ID, Route_ID;

------- Agents with on-time % <80% ------
SELECT d.Agent_ID,
       ROUND(100 * SUM(CASE WHEN Delivery_Delay_Days = 0 THEN 1 ELSE 0 END) / COUNT(*),2) AS on_time_prcnt
FROM Orders o
JOIN deliveryagents d ON o.Route_ID = d.Route_ID
GROUP BY Agent_ID
HAVING on_time_prcnt < 80;

----- Comparing avg speed of Top 5 vs Bottom 5 agents ------
WITH agent_speed AS (
  SELECT o.Customer_ID,
         AVG( CASE WHEN o.Average_delivery_time > 0 THEN (r.Distance_KM / (o.Average_delivery_time/60)) END ) AS avg_speed_kmph,
         ROUND(100 * SUM(CASE WHEN Delivery_Delay_Days = 0 THEN 1 ELSE 0 END) / COUNT(*),2) AS on_time_prct
  FROM Orders o
  JOIN routes r ON o.Route_ID = r.Route_ID
  GROUP BY o.Customer_ID
)
SELECT 'Top5' AS bucket, AVG(avg_speed_kmph) AS avg_speed_kmph
FROM (SELECT * FROM agent_speed ORDER BY on_time_prct DESC LIMIT 5) t
UNION ALL
SELECT 'Bottom5', AVG(avg_speed_kmph)
FROM (SELECT * FROM agent_speed ORDER BY on_time_prct ASC LIMIT 5) t2;

------ Task 6: Latest checkpoints and time -------
SELECT st.Order_ID, st.Checkpoint, st.Checkpoint_Time, st.Delay_Reason
FROM `shipment track`st
JOIN (
  SELECT Order_ID, MAX(Checkpoint_Time) AS last_time
  FROM `shipment track`
  GROUP BY Order_ID
) 
last_chk ON st.Order_ID = last_chk.Order_ID AND st.Checkpoint_Time = last_chk.last_time;

------ Most common count of delay reasons -------
SELECT Delay_Reason, COUNT(*) AS count
FROM `shipment track`
WHERE Delay_Reason IS NOT NULL AND TRIM(Delay_Reason) <> '' AND LOWER(Delay_Reason) NOT IN ('none','na','n/a')
GROUP BY Delay_Reason
ORDER BY count DESC
LIMIT 10;

----- Orders with > 2 delayed checkpoints -----
SELECT Order_ID, Delay_Reason, COUNT(*) AS delayed_checkpoints
FROM `shipment track`
WHERE Delay_Reason IS NOT NULL AND LOWER(Delay_Reason) NOT IN ('none','')
GROUP BY Order_ID, Delay_Reason
HAVING delayed_checkpoints > 2;

----- Task 7: Average delivery delay per start region ------
SELECT r.Start_Location, 
ROUND(AVG(o.Delivery_Delay_Days),2) AS avg_delay_days
FROM routes r
join orders o
GROUP BY r.Start_Location;

-------- On-time delivery % ------
SELECT 
ROUND(100 * SUM(CASE WHEN Delivery_Delay_Days = 0 THEN 1 ELSE 0 END) / COUNT(*),2) AS on_time_prcnt
FROM Orders;

------ Average traffic delays per route -----
SELECT 
    r.Route_ID,
    r.Start_Location,
    ROUND(AVG(r.Traffic_Delay_Min), 2) AS avg_traffic_delay_min
FROM
    Orders o
        JOIN
    Routes r ON o.Route_ID = r.Route_ID
GROUP BY r.Route_ID , r.Start_Location;
