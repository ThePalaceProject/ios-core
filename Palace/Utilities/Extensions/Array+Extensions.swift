extension Array {
  subscript(safe index: Int) -> Element? {
    get {
      indices.contains(index) ? self[index] : nil
    }
    set {
      if indices.contains(index), let value = newValue {
        self[index] = value
      }
    }
  }
}
