import test from 'node:test';
import assert from 'node:assert/strict';
import { ringRadius, entrancePoint } from '../src/motion.js';
test('latitude breathing is symmetric about the equator', () => {
  for (let i=1;i<23;i++) assert.ok(Math.abs(ringRadius(64,i/23,.8)-ringRadius(64,1-i/23,.8))<1e-10);
});
test('speech has visible but bounded influence on the sphere', () => {
  assert.equal(ringRadius(100,.5,0),100);
  assert.equal(ringRadius(100,.5,1),127);
  assert.equal(ringRadius(100,.5,10),127);
  assert.equal(ringRadius(100,.5,-1),100);
});
test('all scatter points move immediately and arrive together', () => {
  for(const start of [-320,-230,230,320]){
    assert.equal(entrancePoint(start,10,0),start);
    assert.notEqual(entrancePoint(start,10,1),start);
    assert.equal(entrancePoint(start,10,280),10);
    assert.equal(entrancePoint(start,10,500),10);
  }
});
