package com.github.shanjian.swiftremote

interface IrTransmitter {
    fun transmitRaw(frequencyHz: Int, patternUs: IntArray): Boolean
}
